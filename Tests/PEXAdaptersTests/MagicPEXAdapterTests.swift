import Testing
import Foundation
@testable import PEXCore
@testable import PEXAdapters
@testable import PEXParsers

/// Integration test for the real Magic-driven PEX adapter. It runs an actual
/// `magic` extraction against the installed Sky130 PDK, so it is gated on the
/// toolchain (`MagicToolchain.locate()`) and skipped where Magic + the PDK are
/// absent. This is also the PEX reliability gate (PEX-3): the extracted parasitic
/// capacitance of a known metal1 plate must match the documented Sky130 met1
/// substrate capacitance, not merely be plumbed through.
@Suite("MagicPEXAdapter (real tool, gated)")
struct MagicPEXAdapterTests {

    static let toolchain = MagicToolchain.locate()

    private func options() -> PEXRunOptions {
        PEXRunOptions(
            extractMode: .cOnly,
            includeCouplingCaps: true,
            minCapacitanceF: nil,
            minResistanceOhm: nil,
            maxParallelJobs: 1,
            emitRawArtifacts: true,
            emitIRJSON: false,
            strictValidation: true
        )
    }

    private func minimalTechnology() -> TechnologyIR {
        TechnologyIR(
            processName: "sky130A",
            stack: [],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )
    }

    private func makeDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MagicPEXAdapterTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(
        "Extracts the plate ground cap matching the Sky130 met1 physical value",
        .enabled(if: MagicPEXAdapterTests.toolchain != nil),
        .timeLimit(.minutes(2))
    )
    func extractsPhysicallyCorrectPlateCapacitance() async throws {
        let gds = try #require(
            Bundle.module.url(forResource: "pex_plate", withExtension: "gds"),
            "missing fixture pex_plate.gds"
        )
        let working = try makeDir("work")
        let rawOut = try makeDir("raw")
        defer {
            try? FileManager.default.removeItem(at: working)
            try? FileManager.default.removeItem(at: rawOut)
        }

        let context = PEXExecutionContext(
            runID: PEXRunID(),
            corner: PEXCorner(id: "tt"),
            layoutURL: gds,
            sourceNetlistURL: gds,
            topCell: "pex_plate",
            technology: minimalTechnology(),
            options: options(),
            workingDirectory: working,
            rawOutputDirectory: rawOut
        )

        let adapter = MagicPEXAdapter()
        try await adapter.prepare(context)
        let result = try await adapter.execute(context)
        #expect(result.rawOutput.format == .spice)

        let parseContext = PEXParseContext(
            cornerID: context.corner.id, runID: context.runID, technology: nil, options: options()
        )
        let ir = try MagicSPICEParasiticParser().parse(result.rawOutput, context: parseContext)
        #expect(ParasiticIRValidator().validate(ir).isValid)

        // A 10x10 um met1 plate over substrate: Sky130 met1 areacap (~25.8 aF/um^2)
        // x 100 um^2 + perimcap (~40.6 aF/um) x 40 um ~= 4.20 fF.
        let totalGroundCap = ir.nets.map(\.totalGroundCapF).reduce(0, +)
        #expect(
            abs(totalGroundCap - 4.2008e-15) < 0.2e-15,
            "extracted \(totalGroundCap * 1e15) fF, expected ~4.20 fF (Sky130 met1)"
        )
    }
}
