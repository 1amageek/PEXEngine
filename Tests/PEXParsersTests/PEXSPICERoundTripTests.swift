import Foundation
import PEXCore
import PEXParsers
import Testing

@Suite("PEX SPICE binary64 round trip", .timeLimit(.minutes(1)))
struct PEXSPICERoundTripTests {
    @Test(arguments: [UInt64(0x3c173295e4fc1a60), 0x7fefffffffffffff,
                      0x0010000000000000, 0x0000000000000001,
                      0x3fb999999999999a, 0x3ff0000000000001,
                      0x0000000000000000, 0x8000000000000000])
    func composedRecordsRetainEveryBinary64Bit(_ bits: UInt64) throws {
        let original = fixture(value: Double(bitPattern: bits))
        let restored = try composeAndParse(original)
        #expect(restored.elements.count == original.elements.count)
        for element in original.elements {
            let actual = try #require(restored.elements.first { $0.kind == element.kind })
            #expect(actual.value.bitPattern == bits)
            #expect(actual.nodeA == element.nodeA && actual.nodeB == element.nodeB)
        }
    }

    @Test func savedSPEFCapacitanceSurvivesPublicComposition() throws {
        // The saved caller-output-load.spef CAP row 3 (*77) is 3.143861e-07 pF.
        // Source SHA-256: 13b97718084c835365aa6381be4a4bb9d80cbcbc1e39ae717a9bf5781f869f5b.
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "TOP"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM
        *NAME_MAP
        *1 N
        *76 a
        *77 b
        *D_NET *1 3.143861e-07
        *CONN
        *P *76 B
        *P *77 B
        *CAP
        3 *77 3.143861e-07
        *RES
        1 *76 *77 1
        *END
        """
        let url = FileManager.default.temporaryDirectory.appending(path: "pex-roundtrip-\(UUID().uuidString).spef")
        try Data(spef.utf8).write(to: url)
        defer { removeFixture(url) }
        let original = try SPEFPEXParser().parse(.init(format: .spef, fileURLs: [url]), context: context())
        let savedCap = try #require(original.elements.first { $0.kind == .capacitor })
        #expect(savedCap.value.bitPattern == 0x3c173295e4fc1a60)
        let restored = try composeAndParse(original)
        let actualCap = try #require(restored.elements.first { $0.kind == .capacitor })
        #expect(actualCap.value.bitPattern == savedCap.value.bitPattern)
        #expect(actualCap.nodeA == savedCap.nodeA && actualCap.nodeB == savedCap.nodeB)
    }

    @Test func unitConversionDoesNotLoseAdditionalFormattingBits() throws {
        let value = Double(bitPattern: 0x3fb999999999999a)
        let original = fixture(value: value,
            units: .init(resistance: .kiloOhm, capacitance: .picoFarad, coordinate: .micrometer))
        let restored = try composeAndParse(original)
        for element in original.elements {
            let converted: Double
            switch element.kind {
            case .resistor: converted = value * 1_000
            case .capacitor, .coupling: converted = value * 1e-12
            case .inductor: converted = value
            }
            let actual = try #require(restored.elements.first { $0.kind == element.kind })
            #expect(actual.value.bitPattern == converted.bitPattern)
        }
    }

    @Test func negativeAndNonfiniteValuesStillRefuse() {
        for value in [-1.0, -Double.leastNonzeroMagnitude, .infinity, -.infinity, .nan] {
            let expected: PEXSPICEWriterError = value.isFinite ? .negativeValue("C") : .nonFiniteValue("C")
            let original = fixture(value: value)
            #expect(throws: expected) { try PEXSPICEWriter().write(original) }
            #expect(throws: PEXSPICEBackannotationError.writer(expected)) {
                try PEXSPICEBackannotationComposer(options: .init(topCell: "TOP"))
                    .compose(sourceNetlist: source, ir: original)
            }
        }
        let overflow = fixture(value: .greatestFiniteMagnitude,
            units: .init(resistance: .kiloOhm, capacitance: .farad, coordinate: .micrometer))
        #expect(throws: PEXSPICEWriterError.nonFiniteValue("R")) { try PEXSPICEWriter().write(overflow) }
    }

    private var source: String {
        """
        .subckt TOP a b
        Vbase a b 0
        .ends TOP
        XTOP a b TOP
        .end
        """
    }

    private func fixture(value: Double, units: ParasiticUnits = .canonical) -> ParasiticIR {
        let net = NetName("N")
        let a = NodeRef(netName: net, nodeName: NodeName("a"))
        let b = NodeRef(netName: net, nodeName: NodeName("b"))
        return ParasiticIR(version: ParasiticIR.currentVersion, cornerID: "tt", units: units,
            nets: [.init(name: net, nodes: [
                .init(name: a.nodeName, kind: .pin, instancePath: nil, coordinate: nil),
                .init(name: b.nodeName, kind: .pin, instancePath: nil, coordinate: nil)
            ], totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0)],
            elements: [
                .init(id: "R", kind: .resistor, nodeA: a, nodeB: b, value: value, source: .extracted),
                .init(id: "C", kind: .capacitor, nodeA: a, nodeB: nil, value: value, source: .extracted),
                .init(id: "CC", kind: .coupling, nodeA: a, nodeB: b, value: value, source: .extracted),
                .init(id: "L", kind: .inductor, nodeA: a, nodeB: b, value: value, source: .extracted)
            ], metadata: ["topCell": "TOP"])
    }

    private func composeAndParse(_ ir: ParasiticIR) throws -> ParasiticIR {
        let url = FileManager.default.temporaryDirectory.appending(path: "pex-roundtrip-\(UUID().uuidString).spice")
        defer { removeFixture(url) }
        try PEXSPICEBackannotationComposer(options: .init(topCell: "TOP"))
            .write(sourceNetlist: source, ir: ir, to: url)
        return try MagicSPICEParasiticParser().parse(.init(format: .spice, fileURLs: [url]), context: context())
    }

    private func context() -> PEXParseContext {
        .init(cornerID: "tt", runID: PEXRunID(), topCell: "TOP", technology: nil, options: .default)
    }

    private func removeFixture(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("Could not remove round-trip fixture: \(error)") }
    }
}
