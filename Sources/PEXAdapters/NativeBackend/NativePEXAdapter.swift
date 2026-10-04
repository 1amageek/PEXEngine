import Foundation
import CryptoKit
import CircuiteFoundation
import PEXCore
import PEXNative
import PEXPersistence
import LayoutIO

/// Actual in-process RC extraction over captured GDSII/OASIS geometry.
public struct NativePEXAdapter: PEXExtracting, PEXAdapterReadinessProviding {
    public let backendID = "native"
    public let capabilities = PEXBackendCapabilities(supportsCouplingCaps: true, supportsCornerSweep: true,
        supportsIncremental: false, supportsRCReduction: false, nativeOutputFormats: [])
    public let maximumLayoutBytes: Int
    public let maximumCodeImageBytes: Int
    public let maximumEvidenceBytes: Int
    public let cancellationPollInterval: Duration

    public init(maximumLayoutBytes: Int = 256 * 1024 * 1024, maximumCodeImageBytes: Int = 512 * 1024 * 1024,
                maximumEvidenceBytes: Int = 64 * 1024 * 1024, cancellationPollInterval: Duration = .milliseconds(20)) throws {
        guard maximumLayoutBytes > 0, maximumCodeImageBytes > 0, maximumEvidenceBytes > 0,
              cancellationPollInterval > .zero else { throw NativePEXBackendError.invalidLimits }
        self.maximumLayoutBytes = maximumLayoutBytes; self.maximumCodeImageBytes = maximumCodeImageBytes
        self.maximumEvidenceBytes = maximumEvidenceBytes; self.cancellationPollInterval = cancellationPollInterval
    }
    public func toolReadiness(processProfile: PEXProcessProfileReference?) -> PEXExtractorToolReadiness {
        .init(backendID: backendID, status: .ready,
            reason: "Native CPU implementation is linked; each run admits its exact model, configuration, inputs and image.",
            processProfile: processProfile, capabilities: capabilities, diagnostics: [], suggestedActions: [])
    }
    public func supportsCornerSweep(corners: [PEXCorner], processProfile: PEXProcessProfileReference?) -> Bool { true }

    public func prepare(_ context: PEXExecutionContext) async throws {
        try FileManager.default.createDirectory(at: context.rawOutputDirectory, withIntermediateDirectories: true)
    }
    public func cleanup(_ context: PEXExecutionContext) async {}

    public func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        let state = NativePEXCancellationState()
        var image: NativePEXCodeImage?, identity: PEXBackendExecutionIdentity?, artifacts: [PEXGeneratedArtifact] = []
        do {
            let observed = try NativePEXCodeImage.measure(maximumBytes: maximumCodeImageBytes)
            image = observed
            let measuredIdentity = try executionIdentity(image: observed)
            identity = measuredIdentity
            try admit(context)
            guard context.backendSelection.expectedProducer == nil || context.backendSelection.expectedProducer == measuredIdentity.producer else {
                throw NativePEXBackendError.unsupportedRequest("Requested producer differs from the measured implementation")
            }
            let projection = try await calculate(context, state: state)
            state.enter("topologyEvidence")
            let topology = NativePEXTopologyEvidence(projection: projection, image: observed, identity: measuredIdentity, policy: NativePEXBackendPolicy(adapter: self))
            artifacts.append(try write(topology, name: "native-topology.json", context: context, identity: measuredIdentity))
            state.enter("imageStability")
            try observed.verifyUnchanged(maximumBytes: maximumCodeImageBytes)
            try Task.checkCancellation()
            state.enter("canonicalAdmission")
            let terminal = artifact(name: "native-execution.json", context: context, identity: measuredIdentity)
            let result = try PEXAdapterExecutionResult(output: .canonical(projection.ir), generatedArtifacts: artifacts + [terminal],
                executionIdentity: measuredIdentity)
            try await checkCancellation(context)
            state.enter("completed")
            artifacts.append(try write(NativePEXTerminalEvidence(policy: NativePEXBackendPolicy(adapter: self), status: "success", phase: state.stage, cornerID: context.corner.id,
                image: observed, executionIdentity: measuredIdentity, failure: nil), name: "native-execution.json", context: context, identity: measuredIdentity))
            return result
        } catch {
            let actual = state.monitorFailure ?? (error as? NativePEXBackendError)
            let cancelled = actual == .cancelled || error is CancellationError || Task.isCancelled
                || (error as? NativePEXInputError) == .cancelled || (error as? NativePEXCalculationError) == .cancelled
                || (error as? NativePEXElectrodeError) == .cancelled || (error as? NativePEXProjectionError) == .cancelled
            let failure = actual.map { String(describing: $0) } ?? String(describing: error)
            do {
                artifacts.append(try write(NativePEXTerminalEvidence(policy: NativePEXBackendPolicy(adapter: self), status: cancelled ? "cancelled" : "failed", phase: state.stage,
                    cornerID: context.corner.id, image: image, executionIdentity: identity, failure: failure),
                    name: "native-failure.json", context: context, identity: identity))
            } catch let persistenceError {
                throw PEXAdapterExecutionFailure(message: "Native extraction failed; required terminal evidence could not be persisted: \(failure)",
                    stage: .persistence, cornerID: context.corner.id, failureKind: .persistenceFailed,
                    generatedArtifacts: artifacts, executionIdentity: identity, underlying: persistenceError)
            }
            throw PEXAdapterExecutionFailure(message: "Native extraction \(cancelled ? "cancelled" : "failed") during \(state.stage): \(failure)",
                stage: .backendExecution, cornerID: context.corner.id, failureKind: cancelled ? .cancelled : .backendExecutionFailed,
                generatedArtifacts: artifacts, executionIdentity: identity, underlying: error)
        }
    }
    private func admit(_ context: PEXExecutionContext) throws {
        guard context.nativeInput != nil else { throw NativePEXBackendError.missingConfiguration }
        guard context.layoutFormat == .gds || context.layoutFormat == .oas else {
            throw NativePEXBackendError.unsupportedRequest("Native backend admits GDSII/OASIS geometry")
        }
        guard context.options.extractMode == .rc, context.options.includeCouplingCaps,
              context.options.minCapacitanceF == nil, context.options.minResistanceOhm == nil else {
            throw NativePEXBackendError.unsupportedRequest("Native backend requires complete RC with coupling and no operator thresholds")
        }
        guard context.backendSelection.executablePath == nil, context.backendSelection.environmentOverrides.isEmpty else {
            throw NativePEXBackendError.unsupportedRequest("In-process extraction does not consume executable/environment overrides")
        }
    }
    private func checkCancellation(_ context: PEXExecutionContext) async throws {
        try Task.checkCancellation()
        if let check = context.cancellationCheck {
            let value: Bool
            do { value = try await check() }
            catch { throw NativePEXBackendError.cancellationCheckFailed(String(describing: error)) }
            if value { throw NativePEXBackendError.cancelled }
        }
    }
    private enum WorkResult: Sendable { case calculation(NativePEXProjection), monitorStopped }
    func calculate(_ context: PEXExecutionContext, state: NativePEXCancellationState) async throws -> NativePEXProjection {
        try await checkCancellation(context)
        do {
            let projection = try await withThrowingTaskGroup(of: WorkResult.self) { group in
                group.addTask { .calculation(try self.calculateSynchronously(context, state: state)) }
                if context.cancellationCheck != nil {
                    group.addTask {
                        while !Task.isCancelled {
                            do { try await self.checkCancellation(context) }
                            catch is CancellationError { return .monitorStopped }
                            catch {
                                let failure = (error as? NativePEXBackendError) ?? .cancellationCheckFailed(String(describing: error))
                                state.cancel(failure); throw failure
                            }
                            do { try await Task.sleep(for: cancellationPollInterval) }
                            catch is CancellationError { return .monitorStopped }
                        }
                        return .monitorStopped
                    }
                }
                defer { group.cancelAll() }
                while let completed = try await group.next() {
                    if case .calculation(let result) = completed { return result }
                }
                throw NativePEXBackendError.cancelled
            }
            // The group has joined both children before consulting the shared
            // reason. A monitor failure cannot be lost when calculation wins
            // next(), nor be replaced by the lower cooperative-cancel error.
            if let failure = state.monitorFailure { throw failure }
            return projection
        } catch {
            if let failure = state.monitorFailure { throw failure }
            throw error
        }
    }
    private func calculateSynchronously(_ context: PEXExecutionContext, state: NativePEXCancellationState) throws -> NativePEXProjection {
        guard let input = context.nativeInput else { throw NativePEXBackendError.missingConfiguration }
        let cancelled = { state.isCancelled || Task.isCancelled }
        state.enter("configuration")
        let reader = PEXBoundedInputReader()
        let configuration = try JSONDecoder().decode(NativePEXConfiguration.self,
            from: reader.read(input.configurationURL, maximumBytes: input.maximumConfigurationBytes))
        let model = try context.technology.electricalModel(for: context.corner)
        for artifact in model.calibrationArtifacts {
            guard let file = input.calibrations.first(where: { $0.artifactID == artifact }) else { throw NativePEXBackendError.missingCalibration }
            let bytes = try reader.read(file.url, maximumBytes: Int(artifact.byteCount))
            guard UInt64(bytes.count) == artifact.byteCount,
                SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == artifact.digest.hexadecimalValue else {
                throw NativePEXBackendError.calibrationMismatch
            }
            if cancelled() { throw NativePEXBackendError.cancelled }
        }
        state.enter("standardImport")
        let layoutBytes = try reader.read(context.layoutURL, maximumBytes: maximumLayoutBytes)
        // These standard signatures admit the declared format before the owned codec
        // decodes it. Auto-detection must not select a different request format.
        let isOASIS = layoutBytes.starts(with: Data("%SEMI-OASIS\r\n".utf8))
        let isGDS = layoutBytes.count >= 4 && layoutBytes[2] == 0 && layoutBytes[3] == 2
        guard context.layoutFormat == .gds ? isGDS : isOASIS else {
            throw NativePEXBackendError.unsupportedRequest("Standard bytes do not match the declared layout format")
        }
        let document = try MaskDataFormatConverter(tech: configuration.layoutTechnology).importFromData(layoutBytes)
        if cancelled() { throw NativePEXBackendError.cancelled }
        state.enter("capture")
        let prepared = try LayoutPEXInputPreparer().prepare(document: document, topCell: context.topCell,
            configuration: configuration, isCancelled: cancelled)
        state.enter("calculation")
        let network = try RectilinearPEXCalculator().calculate(snapshot: prepared.snapshot, technology: context.technology,
            corner: context.corner, layerNames: configuration.layerNames, maximumCellSpanDatabaseUnits: configuration.maximumCellSpanDatabaseUnits,
            limits: configuration.calculationLimits, isCancelled: cancelled)
        state.enter("electrodes")
        let electrodes = try RectilinearPEXElectrodeBuilder().build(network: network, bindings: configuration.electrodeBindings,
            limits: configuration.electrodeLimits, isCancelled: cancelled)
        state.enter("projection")
        return try CanonicalPEXProjector().project(electrodes: electrodes, netBindings: configuration.netBindings,
            limits: configuration.projectionLimits, isCancelled: cancelled)
    }
    private func write<Value: Encodable>(_ value: Value, name: String, context: PEXExecutionContext,
                                         identity: PEXBackendExecutionIdentity?) throws -> PEXGeneratedArtifact {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        guard bytes.count <= maximumEvidenceBytes else { throw NativePEXBackendError.evidenceByteLimitExceeded }
        let url = context.rawOutputDirectory.appending(path: name)
        try bytes.write(to: url, options: .atomic)
        return artifact(name: name, context: context, identity: identity)
    }
    private func artifact(name: String, context: PEXExecutionContext, identity: PEXBackendExecutionIdentity?) -> PEXGeneratedArtifact {
        .init(kind: .processEvidence, stage: .backendExecution, cornerID: context.corner.id,
            url: context.rawOutputDirectory.appending(path: name),
            provenance: .init(note: "native CPU extraction observation"), producer: identity?.producer)
    }
    private func executionIdentity(image: NativePEXCodeImage) throws -> PEXBackendExecutionIdentity {
        let producer = try ProducerIdentity(kind: .tool, identifier: "pex-native", version: "1.0.0", build: image.digest.hexadecimalValue)
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unsupported"
        #endif
        let digest = try ContentDigest(algorithm: .sha256,
            hexadecimalValue: SHA256.hash(data: Data("native-rectilinear-sheet-v1".utf8)).map { String(format: "%02x", $0) }.joined())
        return try .init(producer: producer, binaryDigest: image.digest,
            invocation: .inProcess(entryPoint: "PEXAdapters.NativePEXAdapter.execute"),
            environment: .init(platform: ProcessInfo.processInfo.operatingSystemVersionString, architecture: architecture,
                toolchain: "compiler-identity-unavailable-at-runtime", environmentDigest: digest))
    }
}
