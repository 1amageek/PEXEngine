import Testing
import Foundation
@testable import PEXCore
@testable import PEXParsers

/// Pure parser tests for the Magic parasitic-SPICE lowering — no Magic install
/// needed, so the normalization/units contract is covered in CI.
@Suite("MagicSPICEParasiticParser")
struct MagicSPICEParasiticParserTests {

    private func options(
        extractMode: PEXExtractMode = .rc,
        includeCoupling: Bool = true,
        minCapacitanceF: Double? = nil,
        minResistanceOhm: Double? = nil
    ) -> PEXRunOptions {
        PEXRunOptions(
            extractMode: extractMode,
            includeCouplingCaps: includeCoupling,
            minCapacitanceF: minCapacitanceF,
            minResistanceOhm: minResistanceOhm,
            maxParallelJobs: 1,
            emitRawArtifacts: false,
            emitIRJSON: false,
            strictValidation: true
        )
    }

    private func parse(
        _ spice: String,
        extractMode: PEXExtractMode = .rc,
        includeCoupling: Bool = true,
        minCapacitanceF: Double? = nil,
        minResistanceOhm: Double? = nil
    ) throws -> ParasiticIR {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "magicpex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(dir) }
        let file = dir.appending(path: "parasitics.spice")
        try Data(spice.utf8).write(to: file)
        let raw = PEXRawOutput(format: .spice, fileURLs: [file])
        let context = PEXParseContext(
            cornerID: PEXCornerID("tt"), runID: PEXRunID(), technology: nil,
            options: options(
                extractMode: extractMode,
                includeCoupling: includeCoupling,
                minCapacitanceF: minCapacitanceF,
                minResistanceOhm: minResistanceOhm
            )
        )
        return try MagicSPICEParasiticParser().parse(raw, context: context)
    }

    @Test("A capacitor to the substrate becomes a grounded capacitor with the right value")
    func groundCapacitor() throws {
        let ir = try parse("""
        * extracted by magic
        .subckt pex_plate
        C0 m1_0_0# VSUBS 4.2008f
        .ends
        """)
        let caps = ir.elements.filter { $0.kind == .capacitor }
        #expect(caps.count == 1)
        #expect(caps.first?.nodeB == nil)
        #expect(abs((caps.first?.value ?? 0) - 4.2008e-15) < 1e-19)
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("Net-to-net capacitors become coupling; device lines are ignored")
    func couplingAndDeviceSkip() throws {
        let ir = try parse("""
        X0 Y A VGND VNB sky130_fd_pr__nfet_01v8 ad=0.169 w=0.65 l=0.15
        C1 A VPWR 0.04571f
        C9 A Y 0.0476f
        """)
        #expect(ir.elements.count == 2)
        #expect(ir.elements.allSatisfy { $0.kind == .coupling })
        let values = ir.elements.map(\.value).sorted()
        let firstValue = try #require(values.first)
        let secondValue = try #require(values.dropFirst().first)
        #expect(abs(firstValue - 0.04571e-15) < 1e-20)
        #expect(abs(secondValue - 0.0476e-15) < 1e-20)
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("A coupling cap is counted once across nets (matches SPEFLowering), not on both ends")
    func couplingCountedOnce() throws {
        let ir = try parse("""
        C1 A VPWR 0.04571f
        C9 A Y 0.0476f
        """)
        let perNetSum = ir.nets.map(\.totalCouplingCapF).reduce(0, +)
        let elementSum = ir.elements.filter { $0.kind == .coupling }.map(\.value).reduce(0, +)
        #expect(abs(perNetSum - elementSum) < 1e-21,
                "sum of per-net coupling totals (\(perNetSum)) must equal the coupling element sum (\(elementSum))")
    }

    @Test("A resistor is counted once across nets, not on both endpoints")
    func resistorCountedOnce() throws {
        let ir = try parse("""
        R0 a b 10
        R1 b c 20
        """)
        let perNetSum = ir.nets.map(\.totalResistanceOhm).reduce(0, +)
        #expect(abs(perNetSum - 30.0) < 1e-9, "expected 10+20=30 total, got \(perNetSum)")
    }

    @Test("Resistor-connected sub-nodes collapse into one intra-net (matches SPEFLowering)")
    func resistorsGroupIntoOneNet() throws {
        // A net split by Magic into Y, Y_1, Y_2 connected by series resistors, plus
        // a ground cap on a sub-node — all belong to the single net "Y".
        let ir = try parse("""
        R0 Y Y_1 5
        R1 Y_1 Y_2 7
        C0 Y_2 VSUBS 1f
        """)
        // One net, named after the clean base node "Y", holding all three nodes.
        #expect(ir.nets.count == 1)
        let net = try #require(ir.nets.first)
        #expect(net.name.value == "Y")
        #expect(Set(net.nodes.map(\.name.value)) == ["Y", "Y_1", "Y_2"])
        // Both resistors and the ground cap are attributed to that one net.
        #expect(abs(net.totalResistanceOhm - 12.0) < 1e-9)
        #expect(abs(net.totalGroundCapF - 1e-15) < 1e-20)
        // Every element references nodes that live in the net (validator-clean).
        #expect(ParasiticIRValidator().validate(ir).isValid)
        #expect(ir.elements.allSatisfy { $0.nodeA.netName.value == "Y" })
    }

    @Test("Capacitors never merge nets (coupling stays cross-net)")
    func couplingDoesNotMergeNets() throws {
        let ir = try parse("C0 A B 0.05f")
        #expect(ir.nets.count == 2, "a coupling cap must not union its two nets")
    }

    @Test("includeCouplingCaps=false drops coupling elements but keeps ground caps")
    func dropsCouplingWhenNotRequested() throws {
        let ir = try parse("""
        C0 m1_0_0# VSUBS 4.2008f
        C1 A VPWR 0.04571f
        """, includeCoupling: false)
        #expect(ir.elements.contains { $0.kind == .capacitor }, "ground cap must be kept")
        #expect(!ir.elements.contains { $0.kind == .coupling }, "coupling must be dropped")
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("Magic SPICE parser applies extractMode and minimum thresholds")
    func extractionOptionsFilterElementsAndModes() throws {
        let spice = """
        C0 A VSUBS 5f
        C1 A VSUBS 0.2f
        C2 A B 6f
        R0 A A_1 10
        R1 A_1 A_2 0.1
        L0 A_2 A_3 2n
        """

        let filtered = try parse(
            spice,
            minCapacitanceF: 1e-15,
            minResistanceOhm: 1.0
        )
        #expect(filtered.elements.filter { $0.kind == .capacitor }.count == 1)
        #expect(filtered.elements.filter { $0.kind == .coupling }.count == 1)
        #expect(filtered.elements.filter { $0.kind == .resistor }.count == 1)
        #expect(filtered.elements.filter { $0.kind == .inductor }.count == 1)
        #expect(abs(filtered.nets.map(\.totalGroundCapF).reduce(0, +) - 5e-15) < 1e-21)
        #expect(abs(filtered.nets.map(\.totalCouplingCapF).reduce(0, +) - 6e-15) < 1e-21)
        #expect(abs(filtered.nets.map(\.totalResistanceOhm).reduce(0, +) - 10.0) < 1e-9)
        #expect(ParasiticIRValidator().validate(filtered).isValid)

        let capacitanceOnly = try parse(spice, extractMode: .cOnly)
        #expect(!capacitanceOnly.elements.contains { $0.kind == .resistor })
        #expect(!capacitanceOnly.elements.contains { $0.kind == .inductor })
        #expect(capacitanceOnly.elements.contains { $0.kind == .capacitor })
        #expect(capacitanceOnly.elements.contains { $0.kind == .coupling })
        #expect(abs(capacitanceOnly.nets.map(\.totalResistanceOhm).reduce(0, +)) < 1e-12)
        #expect(ParasiticIRValidator().validate(capacitanceOnly).isValid)

        let resistanceOnly = try parse(spice, extractMode: .rOnly)
        #expect(resistanceOnly.elements.allSatisfy { $0.kind == .resistor })
        #expect(!resistanceOnly.elements.contains { $0.kind == .inductor })
        #expect(abs(resistanceOnly.nets.map(\.totalGroundCapF).reduce(0, +)) < 1e-24)
        #expect(abs(resistanceOnly.nets.map(\.totalCouplingCapF).reduce(0, +)) < 1e-24)
        #expect(ParasiticIRValidator().validate(resistanceOnly).isValid)
    }

    @Test("Ground-node classification is case-insensitive")
    func groundCaseInsensitive() throws {
        let ir = try parse("C0 net1 vsubs 1f")  // lowercase substrate node
        #expect(ir.elements.first?.kind == .capacitor)
        #expect(ir.elements.first?.nodeB == nil)
    }

    @Test("A resistor line is lowered to a resistor element")
    func resistor() throws {
        let ir = try parse("""
        R0 Y Y_1 12.5
        """)
        let res = ir.elements.filter { $0.kind == .resistor }
        #expect(res.count == 1)
        #expect(abs((res.first?.value ?? 0) - 12.5) < 1e-9)
    }

    @Test("An inductor line is lowered to an inductor element")
    func inductor() throws {
        let ir = try parse("""
        L0 Y Y_1 3n
        """)
        let inductors = ir.elements.filter { $0.kind == .inductor }
        #expect(inductors.count == 1)
        #expect(inductors.first?.nodeA.netName.value == "Y")
        #expect(inductors.first?.nodeB?.netName.value == "Y")
        #expect(abs((inductors.first?.value ?? 0) - 3e-9) < 1e-18)
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("Magic SPICE parser rejects non-SPICE raw output format")
    func parserRejectsWrongRawOutputFormat() throws {
        let context = PEXParseContext(
            cornerID: PEXCornerID("tt"),
            runID: PEXRunID(),
            technology: nil,
            options: options()
        )
        let raw = PEXRawOutput(format: .spef, fileURLs: [])

        do {
            _ = try MagicSPICEParasiticParser().parse(raw, context: context)
            Issue.record("Expected Magic SPICE parser to reject non-SPICE raw output format")
        } catch let error as PEXError {
            #expect(error.kind == .parseFailed)
            #expect(error.message.contains("raw output format 'spef'"))
        } catch {
            Issue.record("Expected PEXError.parseFailed, got \(error)")
        }
    }

    @Test("Magic SPICE parser rejects truncated parasitic element lines")
    func parserRejectsTruncatedParasiticLine() throws {
        #expect(throws: PEXError.self) {
            _ = try parse("C0 net_a net_b")
        }
    }

    @Test("SPICE engineering suffixes scale to canonical SI values")
    func spiceValueScaling() {
        #expect(MagicSPICEParasiticParser.parseSPICEValue("4.2008f").map { abs($0 - 4.2008e-15) < 1e-21 } == true)
        #expect(MagicSPICEParasiticParser.parseSPICEValue("2p").map { abs($0 - 2e-12) < 1e-18 } == true)
        #expect(MagicSPICEParasiticParser.parseSPICEValue("3.5n").map { abs($0 - 3.5e-9) < 1e-15 } == true)
        #expect(MagicSPICEParasiticParser.parseSPICEValue("10meg").map { abs($0 - 1e7) < 1 } == true)
        #expect(MagicSPICEParasiticParser.parseSPICEValue("5k").map { abs($0 - 5000) < 1e-6 } == true)
        #expect(MagicSPICEParasiticParser.parseSPICEValue("0.65").map { abs($0 - 0.65) < 1e-9 } == true)
        #expect(MagicSPICEParasiticParser.parseSPICEValue("1e+06u").map { abs($0 - 1.0) < 1e-9 } == true)
        // Unrecognized suffix fails loud (nil) rather than mis-scaling.
        #expect(MagicSPICEParasiticParser.parseSPICEValue("5x") == nil)
        #expect(MagicSPICEParasiticParser.parseSPICEValue("abc") == nil)
    }
}

private func removeTemporaryItem(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
    }
}
