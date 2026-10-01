import Foundation
import Testing
import PEXCore
import PEXAdapters
import PEXParsers
import PEXPersistence
import PEXRuntime
import PEXTestSupport

@Suite("PEX captured input execution", .timeLimit(.minutes(1)))
struct PEXCapturedInputExecutionTests {
    @Test(arguments: [false, true])
    func executionUsesCapturedFilesWhenOriginalsChange(removeOriginals: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pex-captured-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Failed to remove captured-input fixture: \(error)") }
        }
        let names = ["layout.gds", "source.sp", "technology.json", "primary.rc", "tt.rc", "tech.lef", "library.lef"]
        let originals = names.map { root.appending(path: $0) }
        let technology = makeTechnology("captured-process")
        let contents = try [Data("layout-v1".utf8), Data(".subckt TOP\n.ends TOP\n".utf8),
                            JSONEncoder().encode(technology), Data("primary-v1".utf8), Data("tt-v1".utf8),
                            Data("technology-view-v1".utf8), Data("library-view-v1".utf8)]
        for (url, data) in zip(originals, contents) { try data.write(to: url) }
        let observer = CapturedInputObserver()
        let adapter = SourceChangingAdapter(originals: originals, removeOriginals: removeOriginals, observer: observer)
        let request = PEXRunRequest(
            layoutURL: originals[0], layoutFormat: .gds,
            sourceNetlistURL: originals[1], sourceNetlistFormat: .spice,
            topCell: "TOP", corners: [PEXCorner(id: "tt")], technology: .jsonFile(originals[2]),
            technologyByCorner: ["tt": .jsonFile(originals[2])],
            processProfile: PEXProcessProfileReference(
                profileID: "captured.profile", primaryDeckPath: originals[3].path,
                cornerDeckPaths: ["tt": originals[4].path],
                requiredViewPaths: ["technologyLEF": originals[5].path, "libraryLEF:test": originals[6].path]
            ),
            backendSelection: .mock(), options: options, workingDirectory: root
        )
        let result = try await engine(adapter).run(request)
        #expect(result.status == .success)
        let observation = try #require(await observer.value)
        #expect(observation.contents == [contents[0], contents[1], contents[3], contents[4], contents[5], contents[6]])
        #expect(observation.paths.allSatisfy { $0.hasPrefix(result.manifestURL.deletingLastPathComponent().path + "/") })
        #expect(observation.processName == technology.processName)
        let workspace = PEXRunWorkspace(baseURL: root, runID: result.runID)
        let restored = try PEXArtifactStore(workspace: workspace).loadRequest()
        let inputs = result.artifactManifest.artifacts.filter { $0.stage == .inputValidation || $0.stage == .technologyResolution }
        #expect(try PEXRequestHash.compute(for: restored, inputArtifacts: inputs) == result.requestHash)
    }

    @Test func technologyIsDecodedFromCapturedBytesAfterReadiness() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pex-technology-capture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Failed to remove technology capture fixture: \(error)") }
        }
        let layout = root.appending(path: "layout.gds")
        let netlist = root.appending(path: "source.sp")
        let json = root.appending(path: "technology.json")
        try Data("layout".utf8).write(to: layout)
        try Data(".subckt TOP\n.ends TOP\n".utf8).write(to: netlist)
        try JSONEncoder().encode(makeTechnology("before-readiness")).write(to: json)
        let observer = CapturedInputObserver()
        let adapter = SourceChangingAdapter(
            originals: [], removeOriginals: false, observer: observer,
            readinessTechnologyURL: json, readinessTechnology: makeTechnology("captured-after-readiness")
        )
        let request = PEXRunRequest(
            layoutURL: layout, layoutFormat: .gds, sourceNetlistURL: netlist, sourceNetlistFormat: .spice,
            topCell: "TOP", corners: [PEXCorner(id: "tt")], technology: .jsonFile(json),
            backendSelection: .mock(), options: options, workingDirectory: root
        )
        let result = try await engine(adapter).run(request)
        #expect(result.status == .success)
        let observation = try #require(await observer.value)
        let restored = try PEXArtifactStore(workspace: PEXRunWorkspace(baseURL: root, runID: result.runID)).loadRequest()
        #expect(observation.processName == "captured-after-readiness")
        #expect(try TechnologyResolver().resolve(restored.technology).processName == observation.processName)
    }

    private var options: PEXRunOptions {
        PEXRunOptions(extractMode: .rc, includeCouplingCaps: true, minCapacitanceF: nil,
                      minResistanceOhm: nil, maxParallelJobs: 2, emitRawArtifacts: true,
                      emitIRJSON: true, strictValidation: true, sourceConnectivityPolicy: .disabled)
    }

    private func makeTechnology(_ name: String) -> TechnologyIR {
        TechnologyIR(processName: name, stack: [TechnologyLayer(name: "M1", order: 0, thickness: 1,
                     material: "metal", resistivity: 1)], logicalToPhysicalLayerMap: [:], vias: [],
                     defaultExtractionRules: .default, backendHints: [:])
    }

    private func engine(_ adapter: SourceChangingAdapter) -> DefaultPEXEngine {
        let parsers = PEXParserRegistry()
        parsers.register(SPEFPEXParser())
        return DefaultPEXEngine(adapterRegistry: PEXAdapterRegistry(adapters: [adapter]), parserRegistry: parsers)
    }
}

private struct CapturedInputObservation: Sendable {
    let paths: [String]
    let contents: [Data]
    let processName: String
}

private actor CapturedInputObserver {
    var value: CapturedInputObservation?
    func record(_ observation: CapturedInputObservation) { value = observation }
}

private struct SourceChangingAdapter: PEXExtracting, PEXAdapterReadinessProviding {
    let originals: [URL]
    let removeOriginals: Bool
    let observer: CapturedInputObserver
    var readinessTechnologyURL: URL? = nil
    var readinessTechnology: TechnologyIR? = nil
    private let delegate = MockPEXAdapter()
    var backendID: String { delegate.backendID }
    var capabilities: PEXBackendCapabilities { delegate.capabilities }

    func toolReadiness(processProfile: PEXProcessProfileReference?) -> PEXExtractorToolReadiness {
        if let url = readinessTechnologyURL, let technology = readinessTechnology {
            do { try JSONEncoder().encode(technology).write(to: url) }
            catch { Issue.record("Failed to mutate technology before capture: \(error)") }
        }
        return delegate.toolReadiness(processProfile: processProfile)
    }

    func supportsCornerSweep(corners: [PEXCorner], processProfile: PEXProcessProfileReference?) -> Bool { true }

    func prepare(_ context: PEXExecutionContext) async throws {
        for url in originals {
            if removeOriginals { try FileManager.default.removeItem(at: url) }
            else { try Data("changed-after-capture".utf8).write(to: url) }
        }
        try await delegate.prepare(context)
    }

    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        var urls = [context.layoutURL, context.sourceNetlistURL]
        if let profile = context.processProfile {
            urls += [try #require(profile.primaryDeckPath), try #require(profile.cornerDeckPaths["tt"]),
                     try #require(profile.requiredViewPaths["technologyLEF"]),
                     try #require(profile.requiredViewPaths["libraryLEF:test"])].map { URL(filePath: $0) }
        }
        await observer.record(CapturedInputObservation(paths: urls.map(\.path),
                              contents: try urls.map { try Data(contentsOf: $0) }, processName: context.technology.processName))
        return try await delegate.execute(context)
    }

    func cleanup(_ context: PEXExecutionContext) async { await delegate.cleanup(context) }
}
