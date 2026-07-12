import Foundation
import Testing
@testable import PEXCore
@testable import PEXAdapters
@testable import PEXParsers
@testable import PEXPersistence
@testable import PEXRuntime

@Suite("PEX Corner Technology Tests")
struct PEXCornerTechnologyTests {
    @Test("Per-corner technology is applied, hashed, and reconstructed from captured artifacts")
    func perCornerTechnologyIsAppliedAndReconstructed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pex-corner-technology-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove corner technology fixture: \(error)")
            }
        }

        let layoutURL = directory.appending(path: "layout.gds")
        let netlistURL = directory.appending(path: "source.cir")
        try Data("layout".utf8).write(to: layoutURL)
        try Data(".subckt TOP\n.ends TOP\n".utf8).write(to: netlistURL)

        let observer = TechnologyObserver()
        let engine = DefaultPEXEngine(
            adapterRegistry: PEXAdapterRegistry(adapters: [
                TechnologyObservingAdapter(observer: observer),
            ]),
            parserRegistry: {
                let registry = PEXParserRegistry()
                registry.register(SPEFPEXParser())
                return registry
            }()
        )
        let baseTechnology = makeTechnology(processName: "sky130A")
        let cornerTechnology = makeTechnology(processName: "sky130B")
        let baseTechnologyURL = directory.appending(path: "sky130A.json")
        let cornerTechnologyURL = directory.appending(path: "sky130B.json")
        let encoder = JSONEncoder()
        try encoder.encode(baseTechnology).write(to: baseTechnologyURL)
        try encoder.encode(cornerTechnology).write(to: cornerTechnologyURL)
        let request = PEXRunRequest(
            layoutURL: layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TOP",
            corners: [PEXCorner(id: "tt"), PEXCorner(id: "ss")],
            technology: .jsonFile(baseTechnologyURL),
            technologyByCorner: ["ss": .jsonFile(cornerTechnologyURL)],
            backendSelection: PEXBackendSelection(backendID: "technology-observing"),
            options: PEXRunOptions(
                extractMode: .rc,
                includeCouplingCaps: true,
                minCapacitanceF: nil,
                minResistanceOhm: nil,
                maxParallelJobs: 2,
                emitRawArtifacts: true,
                emitIRJSON: true,
                strictValidation: true,
                sourceConnectivityPolicy: .disabled
            ),
            workingDirectory: directory
        )

        let result = try await engine.run(request)
        #expect(result.status == .success)
        let observations = await observer.values()
        #expect(observations["tt"] == "sky130A")
        #expect(observations["ss"] == "sky130B")
        #expect(result.extractorRun?.request.technologyByCorner["ss"]?.path != cornerTechnologyURL.path(percentEncoded: false))
        #expect(result.extractorRun?.multiCorner.comparisonBasis == .perCornerTechnology)
        #expect(result.extractorRun?.multiCorner.notes.contains {
            $0.contains("process-specific")
        } == true)

        let workspace = PEXRunWorkspace(baseURL: directory, runID: result.runID)
        try FileManager.default.removeItem(at: baseTechnologyURL)
        try FileManager.default.removeItem(at: cornerTechnologyURL)
        let restored = try PEXArtifactStore(workspace: workspace).loadRequest()
        guard case .jsonFile(let restoredBaseURL) = restored.technology,
              case .jsonFile(let restoredCornerURL) = restored.technologyByCorner["ss"] else {
            Issue.record("Captured technology references must remain JSON files")
            return
        }
        #expect(restoredBaseURL != baseTechnologyURL)
        #expect(restoredCornerURL != cornerTechnologyURL)
        #expect(try TechnologyResolver().resolve(restored.technology).processName == "sky130A")
        #expect(try TechnologyResolver().resolve(restored.technologyByCorner["ss"]!).processName == "sky130B")
        let summary = try PEXRunSummaryBuilder().build(manifestURL: workspace.manifestURL)
        #expect(summary.summary.multiCorner.comparisonBasis == .perCornerTechnology)
    }

    private func makeTechnology(processName: String) -> TechnologyIR {
        TechnologyIR(
            processName: processName,
            stack: [TechnologyLayer(
                name: "met1",
                order: 1,
                thickness: 0.35,
                material: "metal",
                resistivity: 2.8e-8
            )],
            logicalToPhysicalLayerMap: ["met1": "met1"],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )
    }
}

private actor TechnologyObserver {
    private var observed: [String: String] = [:]

    func record(corner: String, processName: String) {
        observed[corner] = processName
    }

    func values() -> [String: String] {
        observed
    }
}

private struct TechnologyObservingAdapter: PEXAdapter, PEXAdapterReadinessProviding {
    let observer: TechnologyObserver
    private let delegate = MockPEXAdapter()

    var backendID: String { "technology-observing" }
    var capabilities: PEXBackendCapabilities { delegate.capabilities }

    func toolReadiness(processProfile: PEXProcessProfileReference?) -> PEXExtractorToolReadiness {
        PEXExtractorToolReadiness(
            backendID: backendID,
            status: .ready,
            reason: "Technology observing test adapter is available.",
            processProfile: processProfile,
            capabilities: capabilities,
            diagnostics: [],
            suggestedActions: []
        )
    }

    func supportsCornerSweep(
        corners: [PEXCorner],
        processProfile: PEXProcessProfileReference?
    ) -> Bool {
        true
    }

    func prepare(_ context: PEXExecutionContext) async throws {
        try await delegate.prepare(context)
    }

    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        await observer.record(
            corner: context.corner.id.value,
            processName: context.technology.processName
        )
        return try await delegate.execute(context)
    }

    func cleanup(_ context: PEXExecutionContext) async {
        await delegate.cleanup(context)
    }
}
