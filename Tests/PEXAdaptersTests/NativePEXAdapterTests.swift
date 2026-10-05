import Foundation
import CryptoKit
import Synchronization
import Testing
import CircuiteFoundation
import PEXCore
import PEXNative
import PEXPersistence
import PEXRuntime
import LayoutCore
import LayoutTech
import LayoutIO
import SignoffToolSupport
@testable import PEXAdapters

@Suite("Actual native backend and public run behavior", .timeLimit(.minutes(1)))
struct NativePEXAdapterTests {
    @Test(arguments: [LayoutFileFormat.gds, .oasis])
    func publicRunCalculatesAnalyticalRCAndReloadsObservedIdentity(format: LayoutFileFormat) async throws {
        try await fixture(format: format) { f in
            let adapter = NativePEXAdapter()
            let result = try await DefaultPEXEngine.withDefaults().run(f.request)
            #expect(result.status == .success && result.cornerResults[0].ir != nil)
            let ir = try #require(result.cornerResults[0].ir)
            #expect(abs(ir.elements.filter { $0.kind == .resistor }.reduce(0) { $0 + $1.value } - 0.02) < 1e-14)
            #expect(abs(ir.nets.reduce(0) { $0 + $1.totalGroundCapF } - 5e-16) < 1e-28)
            #expect(result.cornerResults[0].rawOutputURLs.isEmpty && result.artifactManifest.artifacts(kind: .rawOutput).isEmpty)
            let identity = try #require(result.artifactManifest.backendExecutions.first)
            let image = try NativePEXCodeImage.measure()
            #expect(identity.binaryDigest == image.digest && identity.producer.build == image.digest.hexadecimalValue)
            #expect(identity.invocation.mode == .inProcess && identity.producer.identifier == "pex-native")
            #expect(identity.producer.version == "2.0.0")
            let workspace = PEXRunWorkspace(baseURL: f.root, runID: result.runID)
            let resolver = try PEXArtifactResolver(workspace: workspace, manifest: result.artifactManifest)
            let record = try #require(resolver.records(kind: .processEvidence, availability: .available).first {
                $0.declaration.relativePath.stringValue.hasSuffix("native-topology.json")
            })
            let report = try JSONDecoder().decode(NativePEXTopologyEvidence.self, from: Data(contentsOf: resolver.validatedURL(for: record)))
            #expect(report.version == 2 && report.image == image && report.executionIdentity == identity)
            #expect(try report.model.domainDigest() == f.technology.electricalModels![0].domainDigest())
            var obsolete = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
            obsolete["version"] = 1
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(NativePEXTopologyEvidence.self, from: JSONSerialization.data(withJSONObject: obsolete))
            }
            #expect(report.policy == NativePEXBackendPolicy(adapter: adapter))
            #expect(report.components.count == 1 && report.pins.count == 2 && report.numericNodes.count == 1)
            #expect(report.electrodeContacts.count == 2 && report.opens.isEmpty && report.shortComponentIndices.isEmpty)
            #expect(Set(report.numericCapacitorElementIDs + report.numericResistorElementIDs + report.electrodeContacts.map(\.elementID)) == Set(ir.elements.map(\.id)))
            let loaded = try PEXArtifactStore(workspace: workspace).loadResult()
            #expect(loaded.status == .success && loaded.cornerResults[0].ir == ir && loaded.artifactManifest.backendExecutions == result.artifactManifest.backendExecutions)
        }
    }
    @Test func physicalOpenIsRetainedWithoutInventingAConnectingResistor() async throws {
        try await fixture(open: true) { f in
            let result = try await execute(f)
            let report = try topology(result)
            #expect(report.components.count == 2 && report.opens.count == 1)
            #expect(report.opens[0].componentIndices == [0, 1] && report.shortComponentIndices.isEmpty)
            let ir: ParasiticIR
            guard case .canonical(let graph) = result.output else { Issue.record("Expected native canonical output"); return }
            ir = graph
            #expect(ir.elements.filter { $0.kind == .resistor }.count == 2)
            #expect(report.ports.map(\.componentIndex) == [0, 1])
        }
    }
    @Test func physicalShortRetainsBothClaimantsAndDedicatedPhysicalNodes() async throws {
        try await fixture(short: true) { f in
            let result = try await execute(f), report = try topology(result)
            #expect(report.shortComponentIndices == [0] && report.components[0].declaredNets.count == 2)
            #expect(Set(report.ports.map { $0.terminal.netName }) == Set([NetName("SIGNAL"), NetName("OTHER")]))
            #expect(report.numericNodes.allSatisfy { ![NetName("SIGNAL"), NetName("OTHER")].contains($0.reference.netName) })
            #expect(report.ports.map(\.componentIndex) == [0, 0] && report.electrodeContacts.count == 2)
        }
    }
    @Test func failedLowerBudgetKeepsImageAndTerminalEvidenceWithoutCanonicalOutput() async throws {
        try await fixture(meshLimit: 0) { f in
            let engine = DefaultPEXEngine(adapterRegistry: .init(adapters: [NativePEXAdapter()]), parserRegistry: .init())
            let result = try await engine.run(f.request)
            #expect(result.status == .failed && result.cornerResults[0].ir == nil)
            #expect(result.artifactManifest.backendExecutions.count == 1)
            #expect(result.artifactManifest.artifacts(kind: .processEvidence).count == 1)
            #expect(result.artifactManifest.artifacts(kind: .parasiticIR).isEmpty)
            #expect(result.artifactManifest.corners[0].failure?.message.contains("meshCells") == true)
        }
    }
    @Test func directInvocationRejectsCalibrationTamperMissingConfigAndMismatchedStandardBytes() async throws {
        try await fixture { f in
            let adapter = NativePEXAdapter()
            try Data("changed bytes".utf8).write(to: f.calibrationURL)
            let tampered = try await failure(adapter, context: f.context)
            #expect(tampered.message.contains("calibrationMismatch") && tampered.executionIdentity != nil)
            try f.calibrationBytes.write(to: f.calibrationURL)
            let missing = try await failure(adapter, context: f.contextReplacing(nativeInput: .some(nil)))
            #expect(missing.message.contains("missingConfiguration"))
            let wrongFormat = try await failure(adapter, context: f.contextReplacing(layoutFormat: .oas))
            #expect(wrongFormat.message.contains("declared layout format"))
            let bounded = try await failure(NativePEXAdapter(maximumLayoutBytes: 1), context: f.context)
            #expect(bounded.generatedArtifacts.count == 1 && bounded.message.contains("byte ceiling"))
        }
    }
    @Test func unsupportedModesThresholdsAndExternalOverridesFailExplicitly() async throws {
        try await fixture { f in
            let adapter = NativePEXAdapter()
            for mode in [PEXExtractMode.cOnly, .rOnly] {
                let options = PEXRunOptions(extractMode: mode, includeCouplingCaps: true, minCapacitanceF: nil,
                    minResistanceOhm: nil, maxParallelJobs: 1, emitRawArtifacts: true, emitIRJSON: true, strictValidation: true)
                #expect(try await failure(adapter, context: f.contextReplacing(options: options)).message.contains("complete RC"))
            }
            let options = PEXRunOptions(extractMode: .rc, includeCouplingCaps: false, minCapacitanceF: nil,
                minResistanceOhm: nil, maxParallelJobs: 1, emitRawArtifacts: true, emitIRJSON: true, strictValidation: true)
            #expect(try await failure(adapter, context: f.contextReplacing(options: options)).message.contains("complete RC"))
            #expect(try await failure(adapter, context: f.contextReplacing(selection: .init(backendID: "native", executablePath: "/unused"))).message.contains("overrides"))
            let expected = try ProducerIdentity(kind: .tool, identifier: "pex-native", version: "different", build: String(repeating: "0", count: 64))
            let rejected = try await failure(adapter, context: f.contextReplacing(selection: .init(backendID: "native", expectedProducer: expected)))
            #expect(rejected.executionIdentity?.producer != expected && rejected.message.contains("Requested producer"))
        }
    }
    @Test func asyncCancellationInterruptsActualCalculationAndJoinsItsMonitor() async throws {
        try await fixture(span: 5) { f in
            let calls = Mutex(0)
            let context = f.contextReplacing(check: {
                let count = calls.withLock { $0 += 1; return $0 }
                return count >= 3
            })
            let rejected = try await failure(NativePEXAdapter(cancellationPollInterval: .milliseconds(1)), context: context)
            #expect(rejected.failureKind == .cancelled && rejected.executionIdentity != nil)
            #expect(rejected.generatedArtifacts.allSatisfy { !$0.url.lastPathComponent.contains("topology") })
            let finished = calls.withLock { $0 }
            try await Task.sleep(for: .milliseconds(10))
            #expect(calls.withLock { $0 } == finished && finished >= 3)
        }
    }
    @Test func callbackErrorIsNotRoundedToCancellationOrSuccessAndMonitorEnds() async throws {
        enum CheckError: Error { case unavailable }
        try await fixture(span: 5) { f in
            let calls = Mutex(0)
            let context = f.contextReplacing(check: {
                if calls.withLock({ $0 += 1; return $0 }) >= 3 { throw CheckError.unavailable }
                return false
            })
            let rejected = try await failure(NativePEXAdapter(cancellationPollInterval: .milliseconds(1)), context: context)
            #expect(rejected.failureKind == .backendExecutionFailed && rejected.message.contains("cancellationCheckFailed"))
            let count = calls.withLock { $0 }; try await Task.sleep(for: .milliseconds(10))
            #expect(calls.withLock { $0 } == count)
        }
    }
    @Test func monitorFailureDuringSynchronousCalculationKeepsItsOriginalReason() async throws {
        enum CheckError: Error { case unavailable }
        try await fixture(span: 5) { f in
            let state = NativePEXCancellationState()
            let context = f.contextReplacing(check: {
                if state.stage == "calculation" { throw CheckError.unavailable }
                return false
            })
            do { _ = try await NativePEXAdapter(cancellationPollInterval: .milliseconds(1)).calculate(context, state: state)
                Issue.record("Monitor error must interrupt numerical work") }
            catch {
                #expect(state.monitorFailure == .cancellationCheckFailed("unavailable"))
                #expect(state.stage == "calculation")
                #expect(error as? NativePEXBackendError == .cancellationCheckFailed("unavailable"))
            }
        }
    }
    @Test func requiredEvidenceFailureCannotPublishSuccessfulCanonicalResult() async throws {
        try await fixture { f in
            let rejected = try await failure(NativePEXAdapter(maximumEvidenceBytes: 1), context: f.context)
            #expect(rejected.failureKind == .persistenceFailed && rejected.executionIdentity != nil)
            #expect(rejected.generatedArtifacts.isEmpty)
        }
    }
    @Test func requiredSPEFTopologyFailureRetainsCanonicalAndEarlierStandardEvidence() async throws {
        try await fixture(short: true) { f in
            let result = try await DefaultPEXEngine.withDefaults().run(f.request)
            #expect(result.status == .failed && result.cornerResults[0].ir == nil)
            #expect(result.artifactManifest.corners[0].failure?.stage == .persistence)
            #expect(result.artifactManifest.corners[0].failure?.message.contains("SPEF") == true)
            #expect(result.artifactManifest.artifacts(kind: .spefRoundTrip).first?.availability == .missing)
            #expect(result.artifactManifest.artifacts(kind: .spiceBackannotation).first?.availability == .available)
            #expect(result.artifactManifest.artifacts(kind: .parasiticIR).first?.availability == .available)
            #expect(result.artifactManifest.artifacts(kind: .processEvidence).count == 2)
            #expect(result.artifactManifest.backendExecutions.count == 1)
            let store = PEXArtifactStore(workspace: .init(baseURL: f.root, runID: result.runID))
            let diagnosticIR = try store.loadIR(for: "tt")
            #expect(diagnosticIR.elements.contains { $0.kind == .resistor && $0.nodeB?.netName != $0.nodeA.netName })
            let restored = try store.loadResult()
            #expect(restored.status == .failed && restored.cornerResults[0].ir == nil)
            // Manifest clock observations are encoded at ISO-8601 precision;
            // retained declarations, content identity, availability and failure remain exact.
            #expect(restored.artifactManifest.corners == result.artifactManifest.corners)
            #expect(restored.artifactManifest.backendExecutions == result.artifactManifest.backendExecutions)
            #expect(restored.artifactManifest.artifacts.map(\.declaration) == result.artifactManifest.artifacts.map(\.declaration))
            #expect(restored.artifactManifest.artifacts.map(\.payload) == result.artifactManifest.artifacts.map(\.payload))
            #expect(restored.artifactManifest.artifacts.map(\.provenance) == result.artifactManifest.artifacts.map(\.provenance))
            let completeness = try PEXArtifactResolver(manifestURL: result.manifestURL).completenessReport()
            #expect(!completeness.issues.contains { $0.kind == .duplicateArtifactID || $0.kind == .failedCornerWithoutEvidence })
        }
    }

    @Test func defaultNativeRetryUsesCapturedInputsAfterEveryOriginalIsRemoved() async throws {
        try await fixture { f in
            let engine = DefaultPEXEngine.withDefaults()
            let failed = try await engine.run(f.request, cancellationCheck: { true })
            #expect(failed.status == .failed)
            let store = PEXArtifactStore(workspace: .init(baseURL: f.root, runID: failed.runID))
            let captured = try store.loadRequest()
            try removeOriginals(f)
            let resumed = try await engine.retryFailedCorners(captured, from: try store.loadResult())
            #expect(resumed.status == .success && resumed.resumedFromRunID == failed.runID)
            #expect(resumed.requestHash == failed.requestHash)
            let ir = try #require(resumed.cornerResults.first?.ir)
            #expect(abs(ir.elements.filter { $0.kind == .resistor }.reduce(0) { $0 + $1.value } - 0.02) < 1e-14)
            #expect(resumed.artifactManifest.artifacts(kind: .spiceBackannotation).first?.availability == .available)
            #expect(resumed.artifactManifest.artifacts(kind: .spefRoundTrip).first?.availability == .available)
        }
    }

    @Test func executableCLIExtractsAndRejectsRetryFromAnotherActualImage() async throws {
        try await fixture { f in
            let executable = try cliExecutable()
            let technology = f.root.appending(path: "technology.json")
            let reference = f.root.appending(path: "native-input.json")
            try JSONEncoder().encode(f.technology).write(to: technology)
            try JSONEncoder().encode(try #require(f.request.nativeInput)).write(to: reference)
            let output = f.root.appending(path: "cli-runs")
            let runner = TimedProcessRunner(timeoutSeconds: 20)
            let extraction = try await runner.run(executableURL: executable, arguments: ["extract", "--layout", f.request.layoutURL.path,
                "--netlist", f.request.sourceNetlistURL.path, "--top-cell", "TOP", "--technology", technology.path,
                "--native-input", reference.path, "--backend", "native", "--corner", "tt", "--out", output.path, "--json"])
            #expect(extraction.exitCode == 0, "\(extraction.standardError)\n\(extraction.standardOutput)")
            let json = try #require(try JSONSerialization.jsonObject(with: extraction.standardOutputData) as? [String: Any])
            let manifest = URL(filePath: try #require((json["manifestURL"] as? String).flatMap { URL(string: $0)?.path }))
            let resolver = try PEXArtifactResolver(manifestURL: manifest)
            #expect(resolver.manifest.backendID == "native" && resolver.manifest.status == .success)
            #expect(resolver.manifest.backendExecutions.first?.invocation.mode == .inProcess)
            let failed = try await DefaultPEXEngine.withDefaults().run(f.request, cancellationCheck: { true })
            try removeOriginals(f)
            try FileManager.default.removeItem(at: technology)
            try FileManager.default.removeItem(at: reference)
            let retainedBefore = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
                .filter { FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path) }
            let retry = try await runner.run(executableURL: executable, arguments: ["retry", "--run", failed.manifestURL.path, "--json"])
            let cliIdentity = try #require(resolver.manifest.backendExecutions.first)
            let parentIdentity = try #require(failed.artifactManifest.backendExecutions.first)
            #expect(cliIdentity.binaryDigest != parentIdentity.binaryDigest)
            #expect(retry.exitCode == 3, "\(retry.standardError)\n\(retry.standardOutput)")
            #expect(retry.standardError.contains("Retry observed a different backend implementation"))
            #expect(retry.standardOutputData.isEmpty)
            let retainedAfter = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
                .filter { FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path) }
            #expect(Set(retainedAfter) == Set(retainedBefore))
            #expect(try PEXArtifactResolver(manifestURL: failed.manifestURL).manifest.status == .failed)
        }
    }

    private func removeOriginals(_ f: NativeBackendFixture) throws {
        try FileManager.default.removeItem(at: f.request.layoutURL)
        try FileManager.default.removeItem(at: f.request.sourceNetlistURL)
        try FileManager.default.removeItem(at: try #require(f.request.nativeInput).configurationURL)
        try FileManager.default.removeItem(at: f.calibrationURL)
    }

    private func cliExecutable() throws -> URL {
        // Bundle.module ties discovery to this test product's built resources.
        var directory = Bundle.module.bundleURL.deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appending(path: "pexengine")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw PEXError.invalidInput("The test product's pexengine executable is missing; build the CLI before native integration")
    }

    private func execute(_ f: NativeBackendFixture) async throws -> PEXAdapterExecutionResult {
        let adapter = NativePEXAdapter(); try await adapter.prepare(f.context); return try await adapter.execute(f.context)
    }
    private func topology(_ result: PEXAdapterExecutionResult) throws -> NativePEXTopologyEvidence {
        let artifact = try #require(result.generatedArtifacts.first { $0.url.lastPathComponent == "native-topology.json" })
        return try JSONDecoder().decode(NativePEXTopologyEvidence.self, from: Data(contentsOf: artifact.url))
    }
    private func failure(_ adapter: NativePEXAdapter, context: PEXExecutionContext) async throws -> PEXAdapterExecutionFailure {
        try await adapter.prepare(context)
        do { _ = try await adapter.execute(context); throw NativePEXBackendError.unsupportedRequest("Expected failure") }
        catch let error as PEXAdapterExecutionFailure { return error }
    }
    private func fixture(format: LayoutFileFormat = .gds, open: Bool = false, short: Bool = false, meshLimit: Int = 100_000, span: Int32 = 1000,
                         _ body: (NativeBackendFixture) async throws -> Void) async throws {
        let f = try NativeBackendFixture(format: format, open: open, short: short, meshLimit: meshLimit, span: span)
        defer { do { try FileManager.default.removeItem(at: f.root) } catch { Issue.record("Cleanup: \(error)") } }
        try await body(f)
    }
}
