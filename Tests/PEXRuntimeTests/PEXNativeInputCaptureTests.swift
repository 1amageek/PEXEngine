import Foundation
import Testing
import CircuiteFoundation
import PEXCore
import PEXAdapters
import PEXParsers
import PEXRuntime
import PEXPersistence
import PEXTestSupport

@Suite("Bounded captured native inputs", .timeLimit(.minutes(1)))
struct PEXNativeInputCaptureTests {
    @Test(arguments: [false, true])
    func originalsCannotChangeExecutionOrReload(remove: Bool) async throws {
        try await fixture { f in
            let observer = NativeInputObserver()
            let adapter = NativeInputFixtureAdapter(originals: [f.configuration, f.calibration], remove: remove, observer: observer)
            let result = try await engine(adapter).run(f.request())
            #expect(result.status == .success)
            let observed = try #require(await observer.inputs)
            #expect(observed.configuration == f.configurationBytes && observed.calibration == f.calibrationBytes)
            #expect(observed.reference.configurationURL.path.hasPrefix(result.manifestURL.deletingLastPathComponent().path))
            #expect(result.artifactManifest.artifacts(kind: .calibrationInput).first?.reference?.id == f.identity)
            #expect(result.artifactManifest.artifacts(kind: .calibrationInput).first?.descriptor.format == .raw)
            let restored = try PEXArtifactStore(workspace: .init(baseURL: f.root, runID: result.runID)).loadRequest()
            let captured = try #require(restored.nativeInput)
            #expect(try Data(contentsOf: captured.configurationURL) == f.configurationBytes)
            #expect(try Data(contentsOf: #require(captured.calibrations.first).url) == f.calibrationBytes)
            #expect(captured.maximumConfigurationBytes == f.configurationBytes.count)
            let records = result.artifactManifest.artifacts.filter { $0.stage == .inputValidation || $0.stage == .technologyResolution }
            #expect(try PEXRequestHash.compute(for: restored, inputArtifacts: records) == result.requestHash)
            let relocated = try f.request(configuration: URL(filePath: "/unavailable/configuration"), calibration: URL(filePath: "/unavailable/calibration"))
            #expect(try PEXRequestHash.compute(for: relocated, inputArtifacts: records) == result.requestHash)
            let differentBudget = try f.request(configurationBudget: f.configurationBytes.count + 1)
            #expect(try PEXRequestHash.compute(for: differentBudget, inputArtifacts: records) != result.requestHash)
        }
    }

    @Test func failedRunRetriesFromCapturedNativeBytesAfterOriginalRemoval() async throws {
        try await fixture { f in
            let firstObserver = NativeInputObserver()
            let failed = try await engine(.init(originals: [f.configuration, f.calibration], remove: true,
                observer: firstObserver, failExecution: true)).run(f.request())
            #expect(failed.status == .failed)
            let restored = try PEXArtifactStore(workspace: .init(baseURL: f.root, runID: failed.runID)).loadRequest()
            let observer = NativeInputObserver()
            let retry = try await engine(.init(originals: [], remove: false, observer: observer)).retryFailedCorners(restored, from: failed)
            #expect(retry.status == .success && retry.requestHash == failed.requestHash)
            #expect(retry.artifactManifest.resumedFromRunID == failed.runID)
            let observed = try #require(await observer.inputs)
            #expect(observed.configuration == f.configurationBytes && observed.calibration == f.calibrationBytes)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func capturedTamperAndMissingBytesRejectReload(calibration: Bool, remove: Bool) async throws {
        try await fixture { f in
            let result = try await engine(.init(originals: [], remove: false, observer: NativeInputObserver())).run(f.request())
            let kind: PEXArtifactKind = calibration ? .calibrationInput : .nativeConfigurationInput
            let record = try #require(result.artifactManifest.artifacts(kind: kind).first)
            let workspace = PEXRunWorkspace(baseURL: f.root, runID: result.runID)
            let url = workspace.runDirectory.appending(path: record.relativePath.stringValue)
            if remove { try FileManager.default.removeItem(at: url) }
            else { try Data(repeating: 120, count: Int(try #require(record.reference).byteCount)).write(to: url) }
            do { _ = try PEXArtifactStore(workspace: workspace).loadRequest(); Issue.record("Tampered/missing native bytes were accepted") }
            catch let error as PEXError { #expect(error.kind == .persistenceFailed) }
        }
    }

    @Test(arguments: ["digest", "missing", "configurationBudget", "modelCoverage"])
    func invalidNativeCaptureFailsBeforeAdapterCallbacks(reason: String) async throws {
        try await fixture { f in
            let observer = NativeInputObserver()
            if reason == "digest" { try Data(repeating: 120, count: f.calibrationBytes.count).write(to: f.calibration) }
            if reason == "missing" { try FileManager.default.removeItem(at: f.calibration) }
            let request = try f.request(configurationBudget: reason == "configurationBudget" ? f.configurationBytes.count - 1 : nil,
                declareCalibration: reason != "modelCoverage")
            do { _ = try await engine(.init(originals: [], remove: false, observer: observer)).run(request); Issue.record("Invalid capture was accepted") }
            catch let error as PEXError { #expect(error.kind == .invalidInput || error.kind == .persistenceFailed) }
            #expect(await observer.prepares == 0)
        }
    }

    @Test func constructorAndDecoderEnforceCaptureIdentityAndBudgets() async throws {
        try await fixture { f in
            let input = try #require(f.request().nativeInput)
            #expect(try JSONDecoder().decode(PEXNativeInputReference.self, from: JSONEncoder().encode(input)) == input)
            for field in ["maximumConfigurationBytes", "maximumCalibrationBytes", "maximumTotalCalibrationBytes", "maximumCalibrationArtifacts"] {
                var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
                json[field] = 0
                #expect(throws: PEXError.self) { try JSONDecoder().decode(PEXNativeInputReference.self, from: JSONSerialization.data(withJSONObject: json)) }
            }
            #expect(throws: PEXError.self) { try PEXNativeInputReference(configurationURL: f.configuration, calibrations: input.calibrations + input.calibrations) }
            #expect(throws: PEXError.self) { try PEXNativeInputReference(configurationURL: f.configuration, calibrations: input.calibrations,
                maximumCalibrationBytes: f.calibrationBytes.count - 1) }
            #expect(throws: PEXError.self) { try PEXNativeInputReference(configurationURL: f.configuration, calibrations: input.calibrations,
                maximumTotalCalibrationBytes: UInt64(f.calibrationBytes.count - 1)) }
            #expect(throws: PEXError.self) { try PEXNativeInputReference(configurationURL: URL(string: "https://invalid.test/config")!, calibrations: []) }
        }
    }

    private func engine(_ adapter: NativeInputFixtureAdapter) -> DefaultPEXEngine {
        let parsers = PEXParserRegistry()
        parsers.register(SPEFPEXParser())
        return DefaultPEXEngine(adapterRegistry: .init(adapters: [adapter]), parserRegistry: parsers)
    }
    private func fixture(_ body: (NativeCaptureFixture) async throws -> Void) async throws {
        let f = try NativeCaptureFixture()
        defer { do { try FileManager.default.removeItem(at: f.root) } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        try await body(f)
    }
}

private struct NativeCaptureFixture {
    let root: URL
    let configuration: URL
    let calibration: URL
    let configurationBytes = Data("{\"nativeContractFixture\":true}".utf8)
    let calibrationBytes = Data("analytical-calibration-fixture".utf8)
    let identity: ArtifactID
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "native-input-\(UUID())")
        configuration = root.appending(path: "configuration.json"); calibration = root.appending(path: "calibration.bin")
        identity = try ArtifactID(digest: ContentDigest(algorithm: .sha256, hexadecimalValue: PEXRequestHash.compute(from: calibrationBytes).value), byteCount: UInt64(calibrationBytes.count))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try configurationBytes.write(to: configuration); try calibrationBytes.write(to: calibration)
        try Data("standard-layout-contract-fixture".utf8).write(to: root.appending(path: "layout.gds"))
        try Data(".subckt TOP\n.ends TOP\n".utf8).write(to: root.appending(path: "source.sp"))
    }
    func request(configuration: URL? = nil, calibration: URL? = nil, configurationBudget: Int? = nil, declareCalibration: Bool = true) throws -> PEXRunRequest {
        let range = PEXDimensionRangeMeters(minimumMeters: 1e-12, maximumMeters: 1)
        let model = PEXElectricalModel(law: .rectilinearSheetV1, processName: "capture-fixture", cornerID: "tt", temperatureKelvin: 298.15,
            voltageVolts: 1.8, parameters: [:], referenceNodeName: "0", calibrationArtifacts: [identity],
            conductors: [.init(layerName: "M1", bottomHeightMeters: 0, thicknessMeters: 1e-6, resistivityOhmMeters: 2e-8,
                groundAreaFaradsPerSquareMeter: 1e-4, groundPerimeterFaradsPerMeter: 1e-10, widthRange: range, lengthRange: range)],
            vias: [], couplings: [.init(firstLayerName: "M1", secondLayerName: "M1", areaFaradsPerSquareMeter: 1e-5, sidewallFarads: 1e-16, gapRange: range)])
        let technology = TechnologyIR(processName: "capture-fixture", stack: [.init(name: "M1", order: 0)], logicalToPhysicalLayerMap: [:],
            vias: [], defaultExtractionRules: .default, backendHints: [:], electricalModels: [model])
        return PEXRunRequest(layoutURL: root.appending(path: "layout.gds"), layoutFormat: .gds, sourceNetlistURL: root.appending(path: "source.sp"),
            sourceNetlistFormat: .spice, topCell: "TOP", corners: [.init(id: "tt")], technology: .inline(technology),
            nativeInput: try .init(configurationURL: configuration ?? self.configuration,
                calibrations: declareCalibration ? [.init(artifactID: identity, url: calibration ?? self.calibration)] : [],
                maximumConfigurationBytes: configurationBudget ?? configurationBytes.count), backendSelection: .mock(),
            options: .init(extractMode: .rc, includeCouplingCaps: true, minCapacitanceF: nil, minResistanceOhm: nil,
                maxParallelJobs: 1, emitRawArtifacts: true, emitIRJSON: true, strictValidation: true, sourceConnectivityPolicy: .disabled), workingDirectory: root)
    }
}

private actor NativeInputObserver {
    var prepares = 0
    var inputs: (reference: PEXNativeInputReference, configuration: Data, calibration: Data)?
    func prepared() { prepares += 1 }
    func record(_ input: PEXNativeInputReference) throws {
        inputs = (input, try Data(contentsOf: input.configurationURL), try Data(contentsOf: #require(input.calibrations.first).url))
    }
}

/// Capture-lifecycle fixture; it does not claim native numerical/image qualification.
private struct NativeInputFixtureAdapter: PEXExtracting, PEXAdapterReadinessProviding {
    let originals: [URL]
    let remove: Bool
    let observer: NativeInputObserver
    var failExecution: Bool = false
    private let delegate = MockPEXAdapter()
    var backendID: String { delegate.backendID }
    var capabilities: PEXBackendCapabilities { delegate.capabilities }
    func toolReadiness(processProfile: PEXProcessProfileReference?) -> PEXExtractorToolReadiness { delegate.toolReadiness(processProfile: processProfile) }
    func prepare(_ context: PEXExecutionContext) async throws {
        await observer.prepared()
        for url in originals {
            if remove { try FileManager.default.removeItem(at: url) }
            else { try Data("changed-original".utf8).write(to: url) }
        }
        try await delegate.prepare(context)
    }
    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        try await observer.record(#require(context.nativeInput))
        let result = try await delegate.execute(context)
        if failExecution {
            throw PEXAdapterExecutionFailure(message: "Capture fixture execution failure", stage: .backendExecution,
                cornerID: context.corner.id, failureKind: .backendExecutionFailed,
                generatedArtifacts: result.generatedArtifacts, executionIdentity: result.executionIdentity)
        }
        return result
    }
    func cleanup(_ context: PEXExecutionContext) async { await delegate.cleanup(context) }
}
