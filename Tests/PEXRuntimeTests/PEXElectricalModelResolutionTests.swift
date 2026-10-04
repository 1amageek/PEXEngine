import Foundation
import Testing
import PEXCore
import PEXParsers
import PEXTestSupport
@testable import PEXRuntime

@Suite("PEX Electrical Model Resolution Tests")
struct PEXElectricalModelResolutionTests {
    private func invalidTechnology() -> TechnologyIR {
        TechnologyIR(processName: "fixture", stack: [], logicalToPhysicalLayerMap: [:], vias: [],
            defaultExtractionRules: .default, backendHints: [:], electricalModels: [
                PEXElectricalModel(law: .rectilinearSheetV1, processName: "fixture", cornerID: PEXCornerID("tt"),
                    temperatureKelvin: -1, voltageVolts: 1, parameters: [:], referenceNodeName: "0",
                    calibrationArtifacts: [], conductors: [], vias: [], couplings: [])
            ])
    }

    @Test func inlineResolutionRejectsInvalidElectricalMeaning() {
        #expect(throws: PEXElectricalModelError.invalidNumber(field: "temperatureKelvin")) {
            try TechnologyResolver().resolve(.inline(invalidTechnology()))
        }
    }

    @Test func capturedJSONResolutionRejectsInvalidElectricalMeaning() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "pex-model-\(UUID()).json")
        try JSONEncoder().encode(invalidTechnology()).write(to: url)
        defer {
            do { try FileManager.default.removeItem(at: url) }
            catch { Issue.record("Failed to remove model fixture: \(error)") }
        }
        #expect(throws: PEXElectricalModelError.invalidNumber(field: "temperatureKelvin")) {
            try TechnologyResolver().resolve(.jsonFile(url))
        }
    }

    @Test(arguments: [false, true])
    func engineRejectsInvalidModelBeforeBackendExecution(jsonInput: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pex-model-gate-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Failed to remove model gate fixture: \(error)") }
        }
        let layout = root.appending(path: "layout.gds")
        let netlist = root.appending(path: "netlist.sp")
        let json = root.appending(path: "technology.json")
        try Data("layout".utf8).write(to: layout)
        try Data(".subckt TOP\n.ends TOP\n".utf8).write(to: netlist)
        try JSONEncoder().encode(invalidTechnology()).write(to: json)
        let parsers = PEXParserRegistry()
        parsers.register(SPEFPEXParser())
        let engine = DefaultPEXEngine(adapterRegistry: PEXAdapterRegistry(adapters: [MockPEXAdapter()]), parserRegistry: parsers)
        let request = PEXRunRequest(layoutURL: layout, layoutFormat: .gds, sourceNetlistURL: netlist,
            sourceNetlistFormat: .spice, topCell: "TOP", corners: [PEXCorner(id: "tt")],
            technology: jsonInput ? .jsonFile(json) : .inline(invalidTechnology()),
            backendSelection: .mock(), options: .default, workingDirectory: root)
        await #expect(throws: PEXElectricalModelError.invalidNumber(field: "temperatureKelvin")) {
            try await engine.run(request)
        }
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        #expect(!files.contains { $0.hasSuffix("extraction.log") || $0.hasSuffix(".spef") })
    }
}
