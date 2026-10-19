import Foundation
import CryptoKit
import CircuiteFoundation
import PEXCore
import PEXNative
import PEXPersistence
import LayoutIO

/// Actual in-process RC extraction over explicitly selected captured standard geometry.
public struct NativePEXAdapter: PEXExtracting, PEXAdapterReadinessProviding {
    public let backendID = "native"
    public let capabilities = PEXBackendCapabilities(supportsCouplingCaps: true, supportsCornerSweep: true,
        supportsIncremental: false, supportsRCReduction: false, nativeOutputFormats: [])
    public let maximumLayoutBytes: Int
    public let maximumCodeImageBytes: Int
    public let maximumEvidenceBytes: Int
    public let routedCalculator: any NativeRoutedPEXCalculating
    public let cancellationPollInterval: Duration

    public static let defaultMaximumLayoutBytes = 256 * 1024 * 1024
    public static let defaultMaximumCodeImageBytes = 512 * 1024 * 1024
    public static let defaultMaximumEvidenceBytes = 64 * 1024 * 1024
    public static let defaultCancellationPollInterval: Duration = .milliseconds(20)

    public init() {
        maximumLayoutBytes = Self.defaultMaximumLayoutBytes
        maximumCodeImageBytes = Self.defaultMaximumCodeImageBytes
        maximumEvidenceBytes = Self.defaultMaximumEvidenceBytes
        cancellationPollInterval = Self.defaultCancellationPollInterval
        routedCalculator = UnionSheetRoutedPEXCalculator()
    }

    public init(maximumLayoutBytes: Int = Self.defaultMaximumLayoutBytes,
                maximumCodeImageBytes: Int = Self.defaultMaximumCodeImageBytes,
                maximumEvidenceBytes: Int = Self.defaultMaximumEvidenceBytes,
                cancellationPollInterval: Duration = Self.defaultCancellationPollInterval,
                routedCalculator: any NativeRoutedPEXCalculating = UnionSheetRoutedPEXCalculator()) throws {
        guard maximumLayoutBytes > 0, maximumCodeImageBytes > 0, maximumEvidenceBytes > 0,
              cancellationPollInterval > .zero else { throw NativePEXBackendError.invalidLimits }
        self.maximumLayoutBytes = maximumLayoutBytes; self.maximumCodeImageBytes = maximumCodeImageBytes
        self.maximumEvidenceBytes = maximumEvidenceBytes; self.cancellationPollInterval = cancellationPollInterval
        self.routedCalculator = routedCalculator
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
            var measuredIdentity = try executionIdentity(image: observed, kind: context.nativeInput?.configurationKind ?? .maskGeometry)
            identity = measuredIdentity
            try admit(context)
            guard context.backendSelection.expectedProducer == nil || context.backendSelection.expectedProducer == measuredIdentity.producer else {
                throw NativePEXBackendError.unsupportedRequest("Requested producer differs from the measured implementation")
            }
            let ir: ParasiticIR
            let physicalTopology: PEXPhysicalTopology
            if context.nativeInput?.configurationKind == .routedOpenRCXV1 {
                let routed = try await calculateRouted(context, state: state)
                measuredIdentity = try executionIdentity(image: observed, kind: .routedOpenRCXV1, prepared: routed.prepared)
                identity = measuredIdentity
                state.enter("routedEvidence")
                artifacts.append(try write(routed.prepared.input, name: NativeRoutedPEXExecutionEvidence.inputFileName, context: context, identity: measuredIdentity))
                artifacts.append(try write(routed.result, name: NativeRoutedPEXExecutionEvidence.resultFileName, context: context, identity: measuredIdentity))
                let source = try NativeRoutedPEXExecutionEvidence(prepared: routed.prepared, context: context,
                    policy: NativePEXBackendPolicy(adapter: self), image: observed, identity: measuredIdentity)
                try source.requireBinding(to: routed.prepared, context: context, policy: NativePEXBackendPolicy(adapter: self),
                    image: observed, identity: measuredIdentity)
                artifacts.append(try write(source, name: NativeRoutedPEXExecutionEvidence.sourceFileName,
                    context: context, identity: measuredIdentity))
                ir = routed.result.ir
                // Successful routed admission guarantees incidence, no shorts and connected signal nets.
                physicalTopology = try .init(openNetCount: 0, shortComponentCount: 0, uncontactedTerminalCount: 0)
            } else {
                let projection = try await calculate(context, state: state)
                state.enter("topologyEvidence")
                let topology = NativePEXTopologyEvidence(projection: projection, image: observed, identity: measuredIdentity, policy: NativePEXBackendPolicy(adapter: self))
                artifacts.append(try write(topology, name: NativePEXTopologyEvidence.artifactFileName, context: context, identity: measuredIdentity))
                ir = projection.ir
                physicalTopology = try .init(openNetCount: topology.opens.count,
                    shortComponentCount: topology.shortComponentIndices.count,
                    uncontactedTerminalCount: topology.ports.filter { $0.componentIndex == nil }.count)
            }
            state.enter("imageStability")
            try observed.verifyUnchanged(maximumBytes: maximumCodeImageBytes)
            try Task.checkCancellation()
            state.enter("canonicalAdmission")
            let terminal = artifact(name: "native-execution.json", context: context, identity: measuredIdentity)
            let result = try PEXAdapterExecutionResult(output: .canonical(ir), generatedArtifacts: artifacts + [terminal],
                executionIdentity: measuredIdentity, physicalTopology: physicalTopology)
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
                || (error as? NativeRoutedPEXPreparationError) == .cancelled || (error as? NativeRoutedPEXError) == .cancelled
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
        guard let input = context.nativeInput else { throw NativePEXBackendError.missingConfiguration }
        switch input.configurationKind {
        case .maskGeometry:
            guard context.layoutFormat == .gds || context.layoutFormat == .oas else {
                throw NativePEXBackendError.unsupportedRequest("Mask Native extraction requires GDSII/OASIS geometry")
            }
        case .routedOpenRCXV1:
            guard context.layoutFormat == .def, context.sourceNetlistFormat == .verilog else {
                throw NativePEXBackendError.unsupportedRequest("Routed Native extraction requires DEF and structural Verilog")
            }
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
    private enum WorkResult<Value: Sendable>: Sendable { case calculation(Value), monitorStopped }
    func calculate(_ context: PEXExecutionContext, state: NativePEXCancellationState) async throws -> NativePEXProjection {
        try await calculateJoined(context, state: state) { try self.calculateSynchronously(context, state: state) }
    }
    private struct RoutedCalculation: Sendable {
        let prepared: PreparedNativeRoutedPEXInput
        let result: NativeRoutedPEXResult
    }
    private func calculateRouted(_ context: PEXExecutionContext, state: NativePEXCancellationState) async throws -> RoutedCalculation {
        try await calculateJoined(context, state: state) {
            let cancelled: @Sendable () -> Bool = { state.isCancelled || Task.isCancelled }
            state.enter("routedPreparation")
            let prepared = try DefaultNativeRoutedPEXInputPreparer().prepare(context: context,
                requiredCornerIDs: context.requestedCornerIDs, isCancelled: cancelled)
            state.enter("routedCalculation")
            let result = try self.routedCalculator.calculate(input: prepared.input, model: prepared.model,
                groundCapacitanceModel: prepared.groundCapacitanceModel,
                maximumCellSpanDatabaseUnits: prepared.maximumCellSpanDatabaseUnits,
                cornerID: context.corner.id, limits: prepared.limits, isCancelled: cancelled)
            guard result.ir.cornerID == context.corner.id, result.selection == prepared.model.selection else {
                throw NativePEXBackendError.unsupportedRequest("Routed calculator returned a different corner or source selection")
            }
            return RoutedCalculation(prepared: prepared, result: result)
        }
    }
    private func calculateJoined<Value: Sendable>(_ context: PEXExecutionContext, state: NativePEXCancellationState,
        operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await checkCancellation(context)
        do {
            let projection = try await withThrowingTaskGroup(of: WorkResult<Value>.self) { group in
                group.addTask { .calculation(try operation()) }
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
        return try CanonicalPEXProjector().project(electrodes: electrodes, netBindings: prepared.netBindings,
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
    static func routedEnvironmentDigest(_ prepared: PreparedNativeRoutedPEXInput) throws -> ContentDigest {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = Data("routedOpenRCXV1:native-union-sheet-area-boundary-v1:\(prepared.maximumCellSpanDatabaseUnits):".utf8)
        bytes.append(try encoder.encode(prepared.model))
        bytes.append(0)
        bytes.append(try encoder.encode(prepared.groundCapacitanceModel))
        bytes.append(0)
        bytes.append(try encoder.encode(prepared.sourceReferences))
        bytes.append(0)
        bytes.append(try encoder.encode(prepared.input))
        return try .init(algorithm: .sha256,
            hexadecimalValue: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    func executionIdentity(image: NativePEXCodeImage, kind: PEXNativeConfigurationKind,
                                   prepared: PreparedNativeRoutedPEXInput? = nil) throws -> PEXBackendExecutionIdentity {
        let producer = try ProducerIdentity(kind: .tool, identifier: "pex-native", version: kind == .maskGeometry ? "3.1.0" : "4.0.0", build: image.digest.hexadecimalValue)
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unsupported"
        #endif
        let digest: ContentDigest
        if kind == .routedOpenRCXV1, let prepared {
            digest = try Self.routedEnvironmentDigest(prepared)
        } else {
            let law = kind == .maskGeometry ? "native-device-aware-contact-admission-v3" : "native-union-sheet-area-boundary-v1:preparation-incomplete"
            digest = try ContentDigest(algorithm: .sha256,
                hexadecimalValue: SHA256.hash(data: Data("\(kind.rawValue):\(law)".utf8)).map { String(format: "%02x", $0) }.joined())
        }
        return try .init(producer: producer, binaryDigest: image.digest,
            invocation: .inProcess(entryPoint: "PEXAdapters.NativePEXAdapter.execute"),
            environment: .init(platform: ProcessInfo.processInfo.operatingSystemVersionString, architecture: architecture,
                toolchain: "compiler-identity-unavailable-at-runtime", environmentDigest: digest))
    }
}
