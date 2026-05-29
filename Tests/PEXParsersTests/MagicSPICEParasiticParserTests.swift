import Testing
import Foundation
@testable import PEXCore
@testable import PEXParsers

/// Pure parser tests for the Magic parasitic-SPICE lowering — no Magic install
/// needed, so the normalization/units contract is covered in CI.
@Suite("MagicSPICEParasiticParser")
struct MagicSPICEParasiticParserTests {

    private func options(includeCoupling: Bool = true) -> PEXRunOptions {
        PEXRunOptions(
            extractMode: .rc,
            includeCouplingCaps: includeCoupling,
            minCapacitanceF: nil,
            minResistanceOhm: nil,
            maxParallelJobs: 1,
            emitRawArtifacts: false,
            emitIRJSON: false,
            strictValidation: true
        )
    }

    private func parse(_ spice: String, includeCoupling: Bool = true) throws -> ParasiticIR {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "magicpex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "parasitics.spice")
        try Data(spice.utf8).write(to: file)
        let raw = PEXRawOutput(format: .spice, fileURLs: [file])
        let context = PEXParseContext(
            cornerID: PEXCornerID("tt"), runID: PEXRunID(), technology: nil,
            options: options(includeCoupling: includeCoupling)
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
        #expect(abs(values[0] - 0.04571e-15) < 1e-20)
        #expect(abs(values[1] - 0.0476e-15) < 1e-20)
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
