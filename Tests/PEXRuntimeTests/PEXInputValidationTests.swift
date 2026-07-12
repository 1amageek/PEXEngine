import Foundation
import Testing
@testable import PEXCore
@testable import PEXRuntime

@Suite("PEX Input Validation Tests")
struct PEXInputValidationTests {
    @Test func missingLayoutIsRejectedBeforeRunWorkspaceCreation() async throws {
        let engine = DefaultPEXEngine.withDefaults()
        let request = PEXRunRequest(
            layoutURL: URL(filePath: "/tmp/pex-missing-layout-\(UUID().uuidString).gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/pex-missing-netlist-\(UUID().uuidString).cir"),
            sourceNetlistFormat: .spice,
            topCell: "TOP",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(TechnologyIR(
                processName: "test",
                stack: [],
                logicalToPhysicalLayerMap: [:],
                vias: [],
                defaultExtractionRules: .default,
                backendHints: [:]
            )),
            backendSelection: .mock(),
            options: .default
        )

        do {
            _ = try await engine.run(request)
            #expect(Bool(false), "Missing layout must be rejected")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("layout"))
        }
    }

    @Test func cornerTechnologyRejectsWhitespaceInCornerID() async throws {
        let engine = DefaultPEXEngine.withDefaults()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pex-corner-validation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove validation fixture: \(error)")
            }
        }
        let layoutURL = root.appending(path: "layout.gds")
        let netlistURL = root.appending(path: "source.cir")
        try Data("layout".utf8).write(to: layoutURL)
        try Data(".subckt TOP\n.ends\n".utf8).write(to: netlistURL)
        let technology = TechnologyIR(
            processName: "test",
            stack: [],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )
        let request = PEXRunRequest(
            layoutURL: layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TOP",
            corners: [PEXCorner(id: "ss")],
            technology: .inline(technology),
            technologyByCorner: [" ss": .inline(technology)],
            backendSelection: .mock(),
            options: .default
        )

        do {
            _ = try await engine.run(request)
            #expect(Bool(false), "Whitespace corner ID must be rejected")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("' ss'"))
        }
    }
}
