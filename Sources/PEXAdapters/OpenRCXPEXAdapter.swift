import Foundation
import CryptoKit
import CircuiteFoundation
import PEXCore
import SignoffToolSupport

/// Production OpenRCX execution through the OpenROAD command-line boundary.
///
/// OpenRCX consumes routed DEF plus the exact LEF and extraction-rule views
/// retained in `PEXProcessProfileReference`. GDSII/OASIS conversion is outside
/// this backend's responsibility and is rejected instead of being inferred.
public struct OpenRCXPEXAdapter: PEXExtracting, PEXAdapterReadinessProviding {
    public let backendID = "openrcx"
    public let capabilities = PEXBackendCapabilities(
        supportsCouplingCaps: true,
        supportsCornerSweep: true,
        supportsIncremental: false,
        supportsRCReduction: true,
        nativeOutputFormats: [.spef]
    )

    private let configuredToolchain: OpenRCXToolchain?
    private let processRunner: any TimedProcessRunning

    public init(
        toolchain: OpenRCXToolchain? = OpenRCXToolchain.locate(),
        processRunner: any TimedProcessRunning = TimedProcessRunner()
    ) {
        self.configuredToolchain = toolchain
        self.processRunner = processRunner
    }

    public func toolReadiness(
        processProfile: PEXProcessProfileReference?
    ) -> PEXExtractorToolReadiness {
        guard let processProfile else {
            return blockedReadiness(
                reason: "OpenRCX requires a process profile with extraction rules and standard views.",
                processProfile: nil,
                actions: ["provide_openrcx_process_profile", "run_pex_doctor"]
            )
        }
        do {
            let toolchain = try OpenRCXToolchain.resolve(
                processProfile: processProfile,
                configuredToolchain: configuredToolchain
            )
            return PEXExtractorToolReadiness(
                backendID: backendID,
                status: .ready,
                reason: "OpenROAD executable, OpenRCX rules, and required LEF views are available.",
                executablePath: toolchain.openROADExecutableURL.path(percentEncoded: false),
                processProfile: processProfile,
                capabilities: capabilities
            )
        } catch {
            return blockedReadiness(
                reason: error.localizedDescription,
                processProfile: processProfile,
                actions: ["configure_OPENROAD_BIN", "provide_openrcx_required_views", "run_pex_doctor"]
            )
        }
    }

    public func supportsCornerSweep(
        corners: [PEXCorner],
        processProfile: PEXProcessProfileReference?
    ) -> Bool {
        guard !corners.isEmpty, let processProfile else { return false }
        if corners.count == 1 {
            guard let path = processProfile.deckPath(for: corners[0].id) else { return false }
            return isNonEmptyRegularFile(URL(filePath: path))
        }
        let paths = corners.compactMap { processProfile.cornerDeckPaths[$0.id.value] }
        guard paths.count == corners.count,
              Set(paths).count == corners.count,
              paths.allSatisfy({ isNonEmptyRegularFile(URL(filePath: $0)) }) else {
            return false
        }
        do {
            let digests = try paths.map { path in
                SHA256.hash(data: try Data(contentsOf: URL(filePath: path)))
            }
            return Set(digests).count == digests.count
        } catch {
            return false
        }
    }

    public func prepare(_ context: PEXExecutionContext) async throws {
        guard context.layoutFormat == .def else {
            throw PEXError(
                kind: .invalidInput,
                stage: .adapterPreparation,
                cornerID: context.corner.id,
                backendID: backendID,
                message: "OpenRCX requires routed DEF input; received \(context.layoutFormat.rawValue)."
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: context.rawOutputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw PEXError(
                kind: .backendExecutionFailed,
                stage: .adapterPreparation,
                cornerID: context.corner.id,
                backendID: backendID,
                message: "Failed to create the OpenRCX output directory.",
                underlyingDescription: String(describing: error)
            )
        }
    }

    public func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        guard let processProfile = context.processProfile else {
            throw PEXError(
                kind: .adapterUnavailable,
                stage: .backendExecution,
                cornerID: context.corner.id,
                backendID: backendID,
                message: "OpenRCX process profile is required."
            )
        }
        let selectedProfile = profileSelectingCornerDeck(processProfile, cornerID: context.corner.id)
        let toolchain: OpenRCXToolchain
        do {
            toolchain = try OpenRCXToolchain.resolve(
                processProfile: selectedProfile,
                executableOverride: context.backendSelection.executablePath,
                configuredToolchain: configuredToolchain
            )
        } catch {
            throw PEXError(
                kind: .adapterUnavailable,
                stage: .backendExecution,
                cornerID: context.corner.id,
                backendID: backendID,
                message: error.localizedDescription
            )
        }

        let outputURL = context.rawOutputDirectory.appending(path: "\(context.corner.id.value).spef")
        let scriptURL = try writeDriver(context: context)
        let driverArtifact = PEXGeneratedArtifact(
            kind: .processDriver,
            stage: .adapterPreparation,
            cornerID: context.corner.id,
            url: scriptURL,
            provenance: PEXArtifactProvenance(note: "OpenRCX Tcl driver")
        )
        let executableDigestBefore = try executableDigest(
            toolchain.openROADExecutableURL,
            context: context,
            retainedArtifacts: [driverArtifact]
        )
        let versionObservation = try await probeVersion(
            toolchain,
            context: context,
            retainedArtifacts: [driverArtifact]
        )
        let environment = executionEnvironment(
            toolchain: toolchain,
            context: context,
            outputURL: outputURL
        )
        let executionIdentity = try makeExecutionIdentity(
            toolchain: toolchain,
            version: versionObservation.version,
            executableDigest: executableDigestBefore,
            scriptURL: scriptURL,
            environment: environment,
            context: context
        )
        try validateExpectedProducer(
            context.backendSelection.expectedProducer,
            observed: executionIdentity.producer,
            context: context
        )
        let retainedBeforeExtraction = ([driverArtifact] + versionObservation.artifacts).map {
            artifact($0, producedBy: executionIdentity.producer)
        }
        let executableDigestAfterProbe = try executableDigest(
            toolchain.openROADExecutableURL,
            context: context,
            retainedArtifacts: retainedBeforeExtraction
        )
        guard executableDigestAfterProbe == executableDigestBefore else {
            throw PEXAdapterExecutionFailure(
                message: "OpenROAD executable changed during version qualification.",
                stage: .backendExecution,
                cornerID: context.corner.id,
                failureKind: .backendExecutionFailed,
                generatedArtifacts: retainedBeforeExtraction,
                executionIdentity: executionIdentity
            )
        }
        let result = try await runOpenROAD(
            toolchain: toolchain,
            scriptURL: scriptURL,
            environment: environment,
            context: context,
            retainedArtifacts: retainedBeforeExtraction,
            outputURL: outputURL,
            executionIdentity: executionIdentity
        )
        let stdoutURL = try writeLog(result.standardOutput, name: "openroad.stdout.log", context: context)
        let stderrURL = try writeLog(result.standardError, name: "openroad.stderr.log", context: context)
        let retainedAfterExtraction = retainedBeforeExtraction
            + logArtifacts(
                stdoutURL: stdoutURL,
                stderrURL: stderrURL,
                context: context,
                producer: executionIdentity.producer
            )
            + existingOutputArtifact(
                outputURL,
                context: context,
                producer: executionIdentity.producer
            )
        let executableDigestAfterExecution = try executableDigest(
            toolchain.openROADExecutableURL,
            context: context,
            retainedArtifacts: retainedAfterExtraction
        )
        guard executableDigestAfterExecution == executableDigestBefore else {
            throw PEXAdapterExecutionFailure(
                message: "OpenROAD executable changed during extraction.",
                stage: .backendExecution,
                cornerID: context.corner.id,
                failureKind: .backendExecutionFailed,
                generatedArtifacts: retainedAfterExtraction,
                executionIdentity: executionIdentity
            )
        }
        guard result.exitCode == 0 else {
            throw PEXAdapterExecutionFailure(
                message: "OpenRCX extraction failed with exit code \(result.exitCode).",
                stage: .backendExecution,
                cornerID: context.corner.id,
                failureKind: .backendExecutionFailed,
                generatedArtifacts: retainedBeforeExtraction
                    + logArtifacts(
                        stdoutURL: stdoutURL,
                        stderrURL: stderrURL,
                        context: context,
                        producer: executionIdentity.producer
                    )
                    + existingOutputArtifact(
                        outputURL,
                        context: context,
                        producer: executionIdentity.producer
                    ),
                executionIdentity: executionIdentity
            )
        }
        guard isNonEmptyRegularFile(outputURL) else {
            throw PEXAdapterExecutionFailure(
                message: "OpenRCX completed without producing a non-empty SPEF artifact.",
                stage: .backendExecution,
                cornerID: context.corner.id,
                failureKind: .backendExecutionFailed,
                generatedArtifacts: retainedBeforeExtraction
                    + logArtifacts(
                        stdoutURL: stdoutURL,
                        stderrURL: stderrURL,
                        context: context,
                        producer: executionIdentity.producer
                    ),
                executionIdentity: executionIdentity
            )
        }
        let identityURL = try writeExecutionIdentity(
            version: versionObservation.version,
            executableDigest: executableDigestBefore,
            context: context,
            retainedArtifacts: retainedAfterExtraction
        )
        return PEXAdapterExecutionResult(
            rawOutput: PEXRawOutput(
                format: .spef,
                fileURLs: [outputURL],
                logURL: stdoutURL,
                metadata: [
                    "generator": "openrcx",
                    "openROADVersion": versionObservation.version,
                    "openROADExecutableSHA256": executableDigestBefore,
                    "extractionRules": toolchain.extractionRulesURL.path(percentEncoded: false),
                    "technologyLEF": toolchain.technologyLEFURL.path(percentEncoded: false),
                    "libraryLEFCount": String(toolchain.libraryLEFURLs.count),
                ]
            ),
            generatedArtifacts: retainedBeforeExtraction + [
                PEXGeneratedArtifact(
                    kind: .processEvidence,
                    stage: .backendExecution,
                    cornerID: context.corner.id,
                    url: identityURL,
                    provenance: PEXArtifactProvenance(note: "OpenROAD execution identity"),
                    producer: executionIdentity.producer
                ),
                PEXGeneratedArtifact(
                    kind: .rawOutput,
                    stage: .backendExecution,
                    cornerID: context.corner.id,
                    url: outputURL,
                    provenance: PEXArtifactProvenance(note: "OpenRCX SPEF output"),
                    producer: executionIdentity.producer
                ),
            ] + logArtifacts(
                stdoutURL: stdoutURL,
                stderrURL: stderrURL,
                context: context,
                producer: executionIdentity.producer
            ),
            executionIdentity: executionIdentity
        )
    }

    public func cleanup(_ context: PEXExecutionContext) async {}

    private func profileSelectingCornerDeck(
        _ profile: PEXProcessProfileReference,
        cornerID: PEXCornerID
    ) -> PEXProcessProfileReference {
        PEXProcessProfileReference(
            profileID: profile.profileID,
            pdkID: profile.pdkID,
            source: profile.source,
            requirementID: profile.requirementID,
            pdkRoot: profile.pdkRoot,
            primaryDeckPath: profile.deckPath(for: cornerID),
            cornerDeckPaths: profile.cornerDeckPaths,
            requiredViewPaths: profile.requiredViewPaths,
            metadata: profile.metadata
        )
    }

    private func probeVersion(
        _ toolchain: OpenRCXToolchain,
        context: PEXExecutionContext,
        retainedArtifacts: [PEXGeneratedArtifact]
    ) async throws -> OpenRCXVersionObservation {
        let result: TimedProcessResult
        do {
            let process = Process()
            process.executableURL = toolchain.openROADExecutableURL
            process.arguments = ["-version"]
            process.environment = baseExecutionEnvironment(
                overrides: context.backendSelection.environmentOverrides
            )
            process.currentDirectoryURL = context.rawOutputDirectory
            result = try await processRunner.run(
                process: process,
                cancellationCheck: context.cancellationCheck
            )
        } catch let error as TimedProcessError {
            let output = processOutput(from: error)
            let artifacts = try retainedProcessOutput(
                standardOutput: output.standardOutput,
                standardError: output.standardError,
                prefix: "openroad.version",
                context: context
            )
            throw PEXAdapterExecutionFailure(
                message: timedProcessMessage(error, operation: "OpenROAD version probe"),
                stage: .backendExecution,
                cornerID: context.corner.id,
                failureKind: timedProcessFailureKind(error),
                generatedArtifacts: retainedArtifacts + artifacts,
                underlying: error
            )
        } catch {
            throw PEXAdapterExecutionFailure(
                message: "OpenROAD version probe failed.",
                stage: .backendExecution,
                cornerID: context.corner.id,
                failureKind: .backendExecutionFailed,
                generatedArtifacts: retainedArtifacts,
                underlying: error
            )
        }
        let artifacts = try retainedProcessOutput(
            standardOutput: result.standardOutput,
            standardError: result.standardError,
            prefix: "openroad.version",
            context: context
        )
        let output = (result.standardOutput + "\n" + result.standardError)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOutput = output.lowercased()
        let failureMarkers = [
            "invalid command",
            "unknown option",
            "unrecognized option",
            "command not found",
            "no such file or directory",
            "traceback (most recent call last)",
        ]
        let versionExpression = #"(?i)\bOpenROAD\b[^\r\n0-9]*([0-9]+\.[0-9]+(?:\.[0-9]+)?)\b"#
        let version = semanticVersion(in: output, expression: versionExpression)
        guard result.exitCode == 0,
              !failureMarkers.contains(where: normalizedOutput.contains),
              let version else {
            throw PEXAdapterExecutionFailure(
                message: "OpenROAD version probe did not return a valid OpenROAD semantic version banner.",
                stage: .backendExecution,
                cornerID: context.corner.id,
                failureKind: .backendExecutionFailed,
                generatedArtifacts: retainedArtifacts + artifacts
            )
        }
        return OpenRCXVersionObservation(version: version, artifacts: artifacts)
    }

    private func semanticVersion(in output: String, expression: String) -> String? {
        do {
            let regularExpression = try NSRegularExpression(pattern: expression)
            let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
            guard let match = regularExpression.firstMatch(in: output, range: fullRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: output) else {
                return nil
            }
            return String(output[range])
        } catch {
            return nil
        }
    }

    private func writeDriver(context: PEXExecutionContext) throws -> URL {
        let url = context.rawOutputDirectory.appending(path: "openrcx.tcl")
        let script = """
        read_lef $::env(PEX_TECH_LEF)
        if {[info exists ::env(PEX_LIBRARY_LEFS)] && $::env(PEX_LIBRARY_LEFS) ne ""} {
            foreach lef [split $::env(PEX_LIBRARY_LEFS) "\u{001F}"] {
                read_lef $lef
            }
        }
        read_def $::env(PEX_DEF)
        define_process_corner -ext_model_index 0 $::env(PEX_CORNER)
        extract_parasitics -ext_model_file $::env(PEX_RULES) -corner_cnt 1
        write_spef -corner $::env(PEX_CORNER) $::env(PEX_OUT)
        """
        do {
            try Data(script.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            throw PEXError.backendExecutionFailed(
                backendID: backendID,
                cornerID: context.corner.id,
                message: "Failed to persist the OpenRCX driver.",
                underlying: error
            )
        }
    }

    private func executableDigest(
        _ executableURL: URL,
        context: PEXExecutionContext,
        retainedArtifacts: [PEXGeneratedArtifact]
    ) throws -> String {
        do {
            let bytes = try Data(contentsOf: executableURL, options: [.mappedIfSafe])
            return SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }
                .joined()
        } catch {
            throw PEXAdapterExecutionFailure(
                message: "OpenROAD executable could not be hashed for execution identity.",
                stage: .backendExecution,
                cornerID: context.corner.id,
                failureKind: .backendExecutionFailed,
                generatedArtifacts: retainedArtifacts,
                underlying: error
            )
        }
    }

    private func writeExecutionIdentity(
        version: String,
        executableDigest: String,
        context: PEXExecutionContext,
        retainedArtifacts: [PEXGeneratedArtifact]
    ) throws -> URL {
        let evidence = OpenRCXExecutionIdentityEvidence(
            backendID: backendID,
            version: version,
            executableSHA256: executableDigest
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let url = context.rawOutputDirectory.appending(path: "openroad.identity.json")
        do {
            try encoder.encode(evidence).write(to: url, options: .atomic)
            return url
        } catch {
            throw PEXAdapterExecutionFailure(
                message: "OpenROAD execution identity could not be persisted.",
                stage: .persistence,
                cornerID: context.corner.id,
                failureKind: .persistenceFailed,
                generatedArtifacts: retainedArtifacts,
                underlying: error
            )
        }
    }

    private func executionEnvironment(
        toolchain: OpenRCXToolchain,
        context: PEXExecutionContext,
        outputURL: URL
    ) -> [String: String] {
        var environment = baseExecutionEnvironment(
            overrides: context.backendSelection.environmentOverrides
        )
        environment["PEX_TECH_LEF"] = toolchain.technologyLEFURL.path(percentEncoded: false)
        environment["PEX_LIBRARY_LEFS"] = toolchain.libraryLEFURLs
            .map { $0.path(percentEncoded: false) }
            .joined(separator: "\u{1F}")
        environment["PEX_DEF"] = context.layoutURL.path(percentEncoded: false)
        environment["PEX_RULES"] = toolchain.extractionRulesURL.path(percentEncoded: false)
        environment["PEX_CORNER"] = context.corner.id.value
        environment["PEX_OUT"] = outputURL.path(percentEncoded: false)
        return environment
    }

    private func makeExecutionIdentity(
        toolchain: OpenRCXToolchain,
        version: String,
        executableDigest: String,
        scriptURL: URL,
        environment: [String: String],
        context: PEXExecutionContext
    ) throws -> PEXBackendExecutionIdentity {
        let digest = try ContentDigest(
            algorithm: .sha256,
            hexadecimalValue: executableDigest
        )
        let producer = try ProducerIdentity(
            kind: .tool,
            identifier: "pex-openrcx",
            version: version,
            build: digest.hexadecimalValue
        )
        let invocation = try ExecutionInvocation.externalProcess(
            executable: toolchain.openROADExecutableURL.path(percentEncoded: false),
            arguments: ["-exit", scriptURL.path(percentEncoded: false)],
            workingDirectory: context.rawOutputDirectory.path(percentEncoded: false)
        )
        let environmentBytes = environment.keys.sorted().reduce(into: Data()) { bytes, key in
            bytes.append(contentsOf: key.utf8)
            bytes.append(0)
            bytes.append(contentsOf: (environment[key] ?? "").utf8)
            bytes.append(0)
        }
        let environmentDigest = try ContentDigest(
            algorithm: .sha256,
            hexadecimalValue: SHA256.hash(data: environmentBytes)
                .map { String(format: "%02x", $0) }
                .joined()
        )
        let fingerprint = try ExecutionEnvironmentFingerprint(
            platform: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.runtimeArchitecture,
            toolchain: version,
            environmentDigest: environmentDigest
        )
        return try PEXBackendExecutionIdentity(
            producer: producer,
            binaryDigest: digest,
            invocation: invocation,
            environment: fingerprint
        )
    }

    private func artifact(
        _ artifact: PEXGeneratedArtifact,
        producedBy producer: ProducerIdentity
    ) -> PEXGeneratedArtifact {
        PEXGeneratedArtifact(
            kind: artifact.kind,
            stage: artifact.stage,
            cornerID: artifact.cornerID,
            url: artifact.url,
            availability: artifact.availability,
            provenance: artifact.provenance,
            producer: producer
        )
    }

    private func validateExpectedProducer(
        _ expected: ProducerIdentity?,
        observed: ProducerIdentity,
        context: PEXExecutionContext
    ) throws {
        guard let expected else { return }
        guard expected == observed else {
            throw PEXAdapterExecutionFailure(
                message: "Observed OpenRCX executable identity does not match the requested producer identity.",
                stage: .backendExecution,
                cornerID: context.corner.id,
                failureKind: .backendExecutionFailed
            )
        }
    }

    private static var runtimeArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private func baseExecutionEnvironment(
        overrides: [String: String]
    ) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let inheritedKeys = ["HOME", "LANG", "LC_ALL", "PATH", "TMPDIR"]
        var environment = inheritedKeys.reduce(into: [String: String]()) { result, key in
            if let value = inherited[key] {
                result[key] = value
            }
        }
        environment.merge(overrides) { _, selected in selected }
        return environment
    }

    private func runOpenROAD(
        toolchain: OpenRCXToolchain,
        scriptURL: URL,
        environment: [String: String],
        context: PEXExecutionContext,
        retainedArtifacts: [PEXGeneratedArtifact],
        outputURL: URL,
        executionIdentity: PEXBackendExecutionIdentity
    ) async throws -> TimedProcessResult {
        let producer = executionIdentity.producer
        let process = Process()
        process.executableURL = toolchain.openROADExecutableURL
        process.arguments = ["-exit", scriptURL.path(percentEncoded: false)]
        process.environment = environment
        process.currentDirectoryURL = context.rawOutputDirectory
        do {
            return try await processRunner.run(
                process: process,
                cancellationCheck: context.cancellationCheck
            )
        } catch let error as TimedProcessError {
            let output = processOutput(from: error)
            let processArtifacts = try retainedProcessOutput(
                standardOutput: output.standardOutput,
                standardError: output.standardError,
                prefix: "openroad",
                context: context,
                producer: producer
            )
            throw PEXAdapterExecutionFailure(
                message: timedProcessMessage(error, operation: "OpenRCX execution"),
                stage: .backendExecution,
                cornerID: context.corner.id,
                failureKind: timedProcessFailureKind(error),
                generatedArtifacts: retainedArtifacts
                    + processArtifacts
                    + existingOutputArtifact(outputURL, context: context, producer: producer),
                executionIdentity: executionIdentity,
                underlying: error
            )
        } catch {
            throw PEXAdapterExecutionFailure(
                message: "OpenRCX process execution failed.",
                stage: .backendExecution,
                cornerID: context.corner.id,
                failureKind: .backendExecutionFailed,
                generatedArtifacts: retainedArtifacts
                    + existingOutputArtifact(outputURL, context: context, producer: producer),
                executionIdentity: executionIdentity,
                underlying: error
            )
        }
    }

    private func writeLog(
        _ value: String,
        name: String,
        context: PEXExecutionContext
    ) throws -> URL {
        let url = context.rawOutputDirectory.appending(path: name)
        do {
            try Data(value.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            throw PEXAdapterExecutionFailure(
                message: "Failed to persist OpenRCX process output.",
                stage: .persistence,
                cornerID: context.corner.id,
                underlying: error
            )
        }
    }

    private func retainedProcessOutput(
        standardOutput: String,
        standardError: String,
        prefix: String,
        context: PEXExecutionContext,
        producer: ProducerIdentity? = nil
    ) throws -> [PEXGeneratedArtifact] {
        let stdoutURL = try writeLog(
            standardOutput,
            name: "\(prefix).stdout.log",
            context: context
        )
        let stderrURL = try writeLog(
            standardError,
            name: "\(prefix).stderr.log",
            context: context
        )
        return logArtifacts(
            stdoutURL: stdoutURL,
            stderrURL: stderrURL,
            context: context,
            producer: producer
        )
    }

    private func processOutput(
        from error: TimedProcessError
    ) -> (standardOutput: String, standardError: String) {
        switch error {
        case .cancellationCheckFailed(_, _, let standardOutput, let standardError),
             .cancelled(_, let standardOutput, let standardError),
             .timedOut(_, _, let standardOutput, let standardError):
            (standardOutput, standardError)
        case .invalidConfiguration, .launchFailed:
            ("", "")
        }
    }

    private func timedProcessFailureKind(_ error: TimedProcessError) -> PEXErrorKind {
        if case .cancelled = error {
            return .cancelled
        }
        if case .timedOut = error {
            return .timedOut
        }
        return .backendExecutionFailed
    }

    private func timedProcessMessage(_ error: TimedProcessError, operation: String) -> String {
        switch error {
        case .cancelled:
            "\(operation) was cancelled."
        case .timedOut:
            "\(operation) timed out."
        default:
            "\(operation) failed."
        }
    }

    private func existingOutputArtifact(
        _ outputURL: URL,
        context: PEXExecutionContext,
        producer: ProducerIdentity? = nil
    ) -> [PEXGeneratedArtifact] {
        guard isNonEmptyRegularFile(outputURL) else { return [] }
        return [PEXGeneratedArtifact(
            kind: .rawOutput,
            stage: .backendExecution,
            cornerID: context.corner.id,
            url: outputURL,
            provenance: PEXArtifactProvenance(note: "Partial OpenRCX SPEF output"),
            producer: producer
        )]
    }

    private func logArtifacts(
        stdoutURL: URL,
        stderrURL: URL,
        context: PEXExecutionContext,
        producer: ProducerIdentity? = nil
    ) -> [PEXGeneratedArtifact] {
        [
            PEXGeneratedArtifact(
                kind: .log,
                stage: .backendExecution,
                cornerID: context.corner.id,
                url: stdoutURL,
                provenance: PEXArtifactProvenance(note: "OpenROAD standard output"),
                producer: producer
            ),
            PEXGeneratedArtifact(
                kind: .log,
                stage: .backendExecution,
                cornerID: context.corner.id,
                url: stderrURL,
                provenance: PEXArtifactProvenance(note: "OpenROAD standard error"),
                producer: producer
            ),
        ]
    }

    private func isNonEmptyRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0
        } catch {
            return false
        }
    }

    private func blockedReadiness(
        reason: String,
        processProfile: PEXProcessProfileReference?,
        actions: [String]
    ) -> PEXExtractorToolReadiness {
        PEXExtractorToolReadiness(
            backendID: backendID,
            status: .blocked,
            reason: reason,
            processProfile: processProfile,
            capabilities: capabilities,
            diagnostics: [
                PEXExtractorDiagnostic(
                    diagnosticID: "openrcx:toolchain-blocked",
                    code: "extractor_toolchain_missing",
                    severity: .blocked,
                    message: reason,
                    suggestedActions: actions
                ),
            ],
            suggestedActions: actions
        )
    }
}

private struct OpenRCXVersionObservation: Sendable {
    let version: String
    let artifacts: [PEXGeneratedArtifact]
}

private struct OpenRCXExecutionIdentityEvidence: Sendable, Codable, Hashable {
    let schemaVersion: Int
    let backendID: String
    let version: String
    let executableSHA256: String

    init(
        backendID: String,
        version: String,
        executableSHA256: String
    ) {
        self.schemaVersion = 1
        self.backendID = backendID
        self.version = version
        self.executableSHA256 = executableSHA256
    }
}
