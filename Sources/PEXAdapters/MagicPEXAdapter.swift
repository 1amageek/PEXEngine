import Foundation
import CryptoKit
import PEXCore

/// Real parasitic-extraction adapter driven by Magic against a profile-declared PDK.
///
/// Extracts parasitic capacitance from `context.layoutURL` for `context.topCell`
/// and writes a SPICE netlist (parsed downstream by `MagicSPICEParasiticParser`).
/// If the Magic toolchain is unavailable it fails loudly rather than fabricating
/// output.
public struct MagicPEXAdapter: PEXExtracting, PEXAdapterReadinessProviding {

    public let backendID = "magic"
    // The default Magic/Sky130 profile exposes one physical extraction table,
    // so the static capability remains false. A request can opt into a true
    // sweep by providing distinct, existing cornerDeckPaths; the runtime gate
    // and execution plan validate and select those decks explicitly.
    public let capabilities = PEXBackendCapabilities(
        supportsCouplingCaps: true,
        supportsCornerSweep: false,
        supportsIncremental: false,
        supportsRCReduction: false,
        nativeOutputFormats: [.spice]
    )

    private let toolchain: MagicToolchain?
    private let runner: ProcessRunner

    public init(toolchain: MagicToolchain? = MagicToolchain.locate(), runner: ProcessRunner = ProcessRunner()) {
        self.toolchain = toolchain
        self.runner = runner
    }

    public func toolReadiness(processProfile: PEXProcessProfileReference?) -> PEXExtractorToolReadiness {
        guard let toolchain else {
            return PEXExtractorToolReadiness(
                backendID: backendID,
                status: .blocked,
                reason: "Magic executable, PDK root, or profile-declared Magic rcfile was not found.",
                processProfile: processProfile,
                capabilities: capabilities,
                diagnostics: [
                    PEXExtractorDiagnostic(
                        diagnosticID: "magic-toolchain:missing",
                        code: "extractor_toolchain_missing",
                        severity: .blocked,
                        message: "Magic toolchain is unavailable; set MAGIC_BIN and PDK_ROOT or install a configured signoff PDK profile.",
                        suggestedActions: [
                            "set_MAGIC_BIN",
                            "set_PDK_ROOT",
                            "install_profile_declared_pdk",
                            "run_pex_doctor",
                        ]
                    )
                ],
                suggestedActions: [
                    "set_MAGIC_BIN",
                    "set_PDK_ROOT",
                    "run_pex_doctor",
                ]
            )
        }

        let profile = processProfile ?? toolchain.processProfileReference
        if let processProfile,
           let validationMessage = profileValidationMessage(processProfile) {
            return blockedReadiness(
                profile: processProfile,
                message: validationMessage
            )
        }
        return PEXExtractorToolReadiness(
            backendID: backendID,
            status: .ready,
            reason: "Magic executable and profile-declared PDK rcfile are available.",
            executablePath: toolchain.magicExecutableURL.path(percentEncoded: false),
            processProfile: profile,
            capabilities: capabilities,
            diagnostics: [],
            suggestedActions: []
        )
    }

    public func supportsCornerSweep(
        corners: [PEXCorner],
        processProfile: PEXProcessProfileReference?
    ) -> Bool {
        guard corners.count > 1, let processProfile else { return false }
        let paths = corners.compactMap { processProfile.cornerDeckPaths[$0.id.value] }
        guard paths.count == corners.count,
              Set(paths).count == corners.count else {
            return false
        }
        guard paths.allSatisfy({ isRegularFile(atPath: $0) }) else {
            return false
        }

        var fingerprints: [String] = []
        for path in paths {
            do {
                let data = try Data(contentsOf: URL(filePath: path))
                let digest = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
                fingerprints.append(digest)
            } catch {
                return false
            }
        }
        return Set(fingerprints).count == fingerprints.count
    }

    public func prepare(_ context: PEXExecutionContext) async throws {
        let fm = FileManager.default
        for dir in [context.rawOutputDirectory, context.workingDirectory] {
            if !fm.fileExists(atPath: dir.path(percentEncoded: false)) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                } catch {
                    throw PEXError(
                        kind: .backendExecutionFailed,
                        stage: .adapterPreparation,
                        cornerID: context.corner.id,
                        backendID: backendID,
                        message: "Failed to create directory \(dir.lastPathComponent)",
                        underlyingDescription: String(describing: error)
                    )
                }
            }
        }
    }

    public func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        let plan = try makeExecutionPlan(for: context)
        let result = try await runMagic(plan, context: context)
        let combinedOutput = result.stdout + "\n" + result.stderr
        let logURL = try writeProcessLog(combinedOutput, context: context)
        try validateMagicResult(result, combinedOutput: combinedOutput, plan: plan, logURL: logURL, context: context)
        return executionResult(plan: plan, logURL: logURL, context: context)
    }

    private func makeExecutionPlan(for context: PEXExecutionContext) throws -> MagicPEXExecutionPlan {
        let toolchain = try executionToolchain(for: context)
        let outputURL = context.rawOutputDirectory.appending(path: "\(context.corner.id.value).spice")
        let settings = MagicPEXExtractionSettings(context: context)
        return MagicPEXExecutionPlan(
            toolchain: toolchain,
            driverURL: try writeExtractionDriver(context),
            outputURL: outputURL,
            settings: settings,
            environment: magicEnvironment(toolchain: toolchain, context: context, outputURL: outputURL, settings: settings)
        )
    }

    private func executionToolchain(for context: PEXExecutionContext) throws -> MagicToolchain {
        guard let toolchain else {
            throw PEXError(
                kind: .adapterUnavailable,
                stage: .backendExecution,
                cornerID: context.corner.id,
                backendID: backendID,
                message: "Magic toolchain not found (set MAGIC_BIN / PDK_ROOT, or install Magic plus a configured signoff PDK profile)",
                underlyingDescription: nil
            )
        }
        let profile = context.processProfile
        if let profile,
           let validationMessage = profileValidationMessage(profile) {
            throw PEXError(
                kind: .adapterUnavailable,
                stage: .backendExecution,
                cornerID: context.corner.id,
                backendID: backendID,
                message: validationMessage,
                underlyingDescription: nil
            )
        }
        let executablePath = trimmedOverride(context.backendSelection.executablePath)
        let selectedExecutable = executablePath ?? toolchain.magicExecutableURL.path(percentEncoded: false)
        let selectedDeck = profile?.cornerDeckPaths[context.corner.id.value]
            ?? profile?.primaryDeckPath
            ?? toolchain.rcFileURL.path(percentEncoded: false)
        let selectedPDKRoot = profile?.pdkRoot
            ?? context.backendSelection.environmentOverrides["PDK_ROOT"]
            ?? toolchain.pdkRoot
        if profile != nil, !isRegularFile(atPath: selectedDeck) {
            throw PEXError(
                kind: .adapterUnavailable,
                stage: .backendExecution,
                cornerID: context.corner.id,
                backendID: backendID,
                message: "Selected Magic extraction deck is not a regular file: \(selectedDeck)",
                underlyingDescription: nil
            )
        }
        guard FileManager.default.isExecutableFile(atPath: selectedExecutable) else {
            throw PEXError(
                kind: .adapterUnavailable,
                stage: .backendExecution,
                cornerID: context.corner.id,
                backendID: backendID,
                message: "Selected Magic executable is not executable: \(selectedExecutable)",
                underlyingDescription: nil
            )
        }
        return MagicToolchain(
            magicExecutableURL: URL(filePath: selectedExecutable),
            rcFileURL: URL(filePath: selectedDeck),
            pdkRoot: selectedPDKRoot,
            profileID: profile?.profileID ?? toolchain.profileID,
            pdkID: profile?.pdkID ?? toolchain.pdkID,
            requirementID: profile?.requirementID ?? toolchain.requirementID
        )
    }

    private func profileValidationMessage(_ profile: PEXProcessProfileReference) -> String? {
        var deckPaths = Set(profile.cornerDeckPaths.values)
        if let primaryDeckPath = profile.primaryDeckPath {
            deckPaths.insert(primaryDeckPath)
        }
        guard !deckPaths.isEmpty else {
            return "Magic process profile must name an existing extraction deck"
        }
        if let invalidDeck = deckPaths.first(where: { !isRegularFile(atPath: $0) }) {
            return "Magic process profile extraction deck is not a regular file: \(invalidDeck)"
        }
        if let pdkRoot = profile.pdkRoot,
           !isDirectory(atPath: pdkRoot) {
            return "Magic process profile PDK root is not an existing directory: \(pdkRoot)"
        }
        return nil
    }

    private func blockedReadiness(
        profile: PEXProcessProfileReference,
        message: String
    ) -> PEXExtractorToolReadiness {
        PEXExtractorToolReadiness(
            backendID: backendID,
            status: .blocked,
            reason: message,
            processProfile: profile,
            capabilities: capabilities,
            diagnostics: [
                PEXExtractorDiagnostic(
                    diagnosticID: "magic-process-profile:invalid",
                    code: "process_profile_invalid",
                    severity: .blocked,
                    message: message,
                    suggestedActions: ["inspect_process_profile", "run_pex_doctor"]
                ),
            ],
            suggestedActions: ["inspect_process_profile", "run_pex_doctor"]
        )
    }

    private func isRegularFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    private func isDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private func writeExtractionDriver(_ context: PEXExecutionContext) throws -> URL {
        // Magic writes intermediate .ext/.res.ext files using the current
        // working directory and derives their names from the top cell. Keep
        // that directory corner-local so parallel corners cannot overwrite
        // one another's extraction state.
        let driverURL = context.rawOutputDirectory.appending(path: "pex_extract.tcl")
        do {
            try Data(MagicToolchain.extractionDriver.utf8).write(to: driverURL)
            return driverURL
        } catch {
            throw PEXError(
                kind: .backendExecutionFailed,
                stage: .backendExecution,
                cornerID: context.corner.id,
                backendID: backendID,
                message: "Failed to write extraction driver",
                underlyingDescription: String(describing: error)
            )
        }
    }

    private func magicEnvironment(
        toolchain: MagicToolchain,
        context: PEXExecutionContext,
        outputURL: URL,
        settings: MagicPEXExtractionSettings
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(context.backendSelection.environmentOverrides) { _, selected in selected }
        environment["PDK_ROOT"] = context.backendSelection.environmentOverrides["PDK_ROOT"] ?? toolchain.pdkRoot
        environment["PEX_GDS"] = context.layoutURL.path(percentEncoded: false)
        environment["PEX_CELL"] = context.topCell
        environment["PEX_OUT"] = outputURL.path(percentEncoded: false)
        environment["PEX_CTHRESH"] = settings.cthresh
        environment["PEX_EXTRESIST"] = settings.extresist
        return environment
    }

    private func trimmedOverride(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func runMagic(
        _ plan: MagicPEXExecutionPlan,
        context: PEXExecutionContext
    ) async throws -> ProcessRunner.ProcessResult {
        do {
            return try await runner.run(
                executableURL: plan.toolchain.magicExecutableURL,
                arguments: [
                    "-dnull", "-noconsole",
                    "-rcfile", plan.toolchain.rcFileURL.path(percentEncoded: false),
                    plan.driverURL.path(percentEncoded: false),
                ],
                environment: plan.environment,
                workingDirectory: context.rawOutputDirectory,
                cancellationCheck: context.cancellationCheck
            )
        } catch let error as PEXError where error.kind == .cancelled {
            throw error
        } catch {
            throw PEXError(
                kind: .backendExecutionFailed,
                stage: .backendExecution,
                cornerID: context.corner.id,
                backendID: backendID,
                message: "Magic process failed to run",
                underlyingDescription: String(describing: error)
            )
        }
    }

    private func writeProcessLog(_ combinedOutput: String, context: PEXExecutionContext) throws -> URL {
        let logURL = context.rawOutputDirectory.appending(path: "extraction.log")
        do {
            try Data(combinedOutput.utf8).write(to: logURL)
            return logURL
        } catch {
            throw PEXAdapterExecutionFailure(
                message: "Failed to write Magic extraction log",
                stage: .persistence,
                cornerID: context.corner.id,
                underlying: error
            )
        }
    }

    private func validateMagicResult(
        _ result: ProcessRunner.ProcessResult,
        combinedOutput: String,
        plan: MagicPEXExecutionPlan,
        logURL: URL,
        context: PEXExecutionContext
    ) throws {
        guard result.exitCode == 0,
              !combinedOutput.contains("PEX_ERROR"),
              FileManager.default.fileExists(atPath: plan.outputURL.path(percentEncoded: false)) else {
            throw PEXAdapterExecutionFailure(
                message: "Magic extraction failed (exit \(result.exitCode))",
                stage: .backendExecution,
                cornerID: context.corner.id,
                generatedArtifacts: [logArtifact(logURL, context: context)]
            )
        }
    }

    private func executionResult(
        plan: MagicPEXExecutionPlan,
        logURL: URL,
        context: PEXExecutionContext
    ) -> PEXAdapterExecutionResult {
        let rawOutput = PEXRawOutput(
            format: .spice,
            fileURLs: [plan.outputURL],
            logURL: logURL,
            metadata: [
                "generator": "magic",
                "cthresh": plan.settings.cthresh,
                "extresist": plan.settings.extresist,
            ]
        )
        return PEXAdapterExecutionResult(
            rawOutput: rawOutput,
            generatedArtifacts: [
                rawOutputArtifact(plan.outputURL, context: context),
                logArtifact(logURL, context: context),
            ]
        )
    }

    private func rawOutputArtifact(_ outputURL: URL, context: PEXExecutionContext) -> PEXGeneratedArtifact {
        PEXGeneratedArtifact(
            kind: .rawOutput,
            stage: .backendExecution,
            cornerID: context.corner.id,
            url: outputURL,
            provenance: PEXArtifactProvenance(note: "magic ext2spice parasitics")
        )
    }

    private func logArtifact(_ logURL: URL, context: PEXExecutionContext) -> PEXGeneratedArtifact {
        PEXGeneratedArtifact(
            kind: .log,
            stage: .backendExecution,
            cornerID: context.corner.id,
            url: logURL,
            provenance: PEXArtifactProvenance(note: "magic process log")
        )
    }

    public func cleanup(_ context: PEXExecutionContext) async {
        // Magic writes intermediate .ext files into the working directory; leave
        // them for inspection (the working directory is run-scoped).
    }
}

private struct MagicPEXExecutionPlan {
    let toolchain: MagicToolchain
    let driverURL: URL
    let outputURL: URL
    let settings: MagicPEXExtractionSettings
    let environment: [String: String]
}

private struct MagicPEXExtractionSettings {
    let cthresh: String
    let extresist: String

    init(context: PEXExecutionContext) {
        cthresh = "0"
        let extractResistance = context.options.extractMode == .rc
            || context.options.extractMode == .rOnly
        extresist = extractResistance ? "on" : "off"
    }
}
