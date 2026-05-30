import Testing
import Foundation
@testable import PEXCore
@testable import PEXAdapters
@testable import PEXParsers

/// F4: real resistance extraction. With extractMode .rc the Magic backend runs
/// `extresist` (threshold 0, after `select top cell`), so the netlist carries
/// resistors, and the parser groups the resistor sub-nodes back into nets.
/// Gated on the toolchain.
@Suite("Magic resistance extraction (real tool, gated)")
struct MagicResistanceExtractionTests {

    static let toolchain = MagicToolchain.locate()

    private func options(_ mode: PEXExtractMode) -> PEXRunOptions {
        PEXRunOptions(
            extractMode: mode, includeCouplingCaps: true,
            minCapacitanceF: nil, minResistanceOhm: nil, maxParallelJobs: 1,
            emitRawArtifacts: true, emitIRJSON: false, strictValidation: true
        )
    }

    private func makeDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MagicR-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func extract(mode: PEXExtractMode, work: URL) async throws -> ParasiticIR {
        let gds = try #require(Bundle.module.url(forResource: "inv1", withExtension: "gds"))
        let context = PEXExecutionContext(
            runID: PEXRunID(), corner: PEXCorner(id: "tt"),
            layoutURL: gds, sourceNetlistURL: gds, topCell: "sky130_fd_sc_hd__inv_1",
            technology: TechnologyIR(processName: "sky130A", stack: [], logicalToPhysicalLayerMap: [:],
                                     vias: [], defaultExtractionRules: .default, backendHints: [:]),
            options: options(mode),
            workingDirectory: work.appending(path: "work"),
            rawOutputDirectory: work.appending(path: "raw")
        )
        let adapter = MagicPEXAdapter()
        try await adapter.prepare(context)
        let result = try await adapter.execute(context)
        let parseContext = PEXParseContext(cornerID: context.corner.id, runID: context.runID,
                                           technology: nil, options: options(mode))
        return try MagicSPICEParasiticParser().parse(result.rawOutput, context: parseContext)
    }

    @Test(
        "extractMode .rc yields real resistors with physically plausible values",
        .enabled(if: MagicResistanceExtractionTests.toolchain != nil),
        .timeLimit(.minutes(2))
    )
    func extractsResistors() async throws {
        let work = try makeDir("rc")
        defer { removeTemporaryItem(work) }
        let ir = try await extract(mode: .rc, work: work)

        let resistors = ir.elements.filter { $0.kind == .resistor }
        #expect(!resistors.isEmpty, "extractMode .rc must emit resistors")
        #expect(resistors.allSatisfy { $0.value.isFinite && $0.value >= 0 })
        // Sky130 local-interconnect/metal segments: ohms..low-kohm range.
        #expect(resistors.allSatisfy { $0.value < 1e5 }, "resistance values should be physically sane")
        #expect(ir.nets.contains { $0.totalResistanceOhm > 0 })
        #expect(ParasiticIRValidator().validate(ir).isValid)
        // The parser must have grouped resistor sub-nodes: at least one net holds
        // more than one node (e.g. Y, Y.n0, Y.t0 ...).
        #expect(ir.nets.contains { $0.nodes.count > 1 }, "resistor sub-nodes should collapse into a net")
    }

    @Test(
        "extractMode .cOnly emits no resistors (capacitance only)",
        .enabled(if: MagicResistanceExtractionTests.toolchain != nil),
        .timeLimit(.minutes(2))
    )
    func capOnlyHasNoResistors() async throws {
        let work = try makeDir("conly")
        defer { removeTemporaryItem(work) }
        let ir = try await extract(mode: .cOnly, work: work)
        #expect(!ir.elements.contains { $0.kind == .resistor })
        #expect(ir.elements.contains { $0.kind == .capacitor || $0.kind == .coupling })
    }
}

private func removeTemporaryItem(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
    }
}
