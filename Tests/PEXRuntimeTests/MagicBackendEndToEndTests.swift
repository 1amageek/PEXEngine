import Testing
import Foundation
@testable import PEXCore
@testable import PEXAdapters
@testable import PEXRuntime

/// End-to-end test that the real Magic PEX backend is reachable through the same
/// engine the `pexengine` CLI uses (`DefaultPEXEngine.withDefaults()`) when a run
/// selects `backendID == "magic"`. This is the A4 wiring proof: selecting the
/// magic backend by id flows a real layout through extraction → parser → IR with
/// physically correct parasitics. Gated on the toolchain; skipped without it.
@Suite("Magic PEX backend end-to-end (real tool, gated)")
struct MagicBackendEndToEndTests {

    static let toolchain = MagicToolchain.locate()

    @Test(
        "Selecting backendID=magic extracts real Sky130 parasitics through the default engine",
        .enabled(if: MagicBackendEndToEndTests.toolchain != nil),
        .timeLimit(.minutes(2))
    )
    func magicBackendSelectedByIDProducesRealParasitics() async throws {
        let gds = try #require(
            Bundle.module.url(forResource: "pex_plate", withExtension: "gds"),
            "missing fixture pex_plate.gds"
        )
        let workDir = FileManager.default.temporaryDirectory
            .appending(path: "MagicBackendE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // The magic adapter ignores the source netlist, but the request requires one.
        let netlist = workDir.appending(path: "top.cir")
        try Data("* placeholder\n.end\n".utf8).write(to: netlist)

        let tech = TechnologyIR(
            processName: "sky130A",
            stack: [],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )

        let request = PEXRunRequest(
            layoutURL: gds,
            layoutFormat: .gds,
            sourceNetlistURL: netlist,
            sourceNetlistFormat: .spice,
            topCell: "pex_plate",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(tech),
            backendSelection: PEXBackendSelection(backendID: "magic"),
            options: PEXRunOptions(
                extractMode: .cOnly,
                includeCouplingCaps: true,
                minCapacitanceF: nil,
                minResistanceOhm: nil,
                maxParallelJobs: 1,
                emitRawArtifacts: true,
                emitIRJSON: true,
                strictValidation: false
            ),
            workingDirectory: workDir
        )

        let engine = DefaultPEXEngine.withDefaults()
        let result = try await engine.run(request)

        #expect(result.status == .success)
        let corner = try #require(result.cornerResults.first)
        let ir = try #require(corner.ir, "magic backend must produce an IR")
        #expect(ir.metadata["sourceFormat"] == "magic-spice",
                "IR must come from the real Magic backend, not the mock")

        let groundCap = ir.nets.map(\.totalGroundCapF).reduce(0, +)
        #expect(
            abs(groundCap - 4.2008e-15) < 0.2e-15,
            "extracted \(groundCap * 1e15) fF, expected ~4.20 fF (Sky130 met1)"
        )
    }
}
