import Foundation
import Testing
@testable import PEXCore
@testable import PEXParsers

@Suite("Lossless SPEF hyphen identity", .timeLimit(.minutes(1)))
struct SPEFHyphenIdentityTests {
    private func fixture(netName: String = "net-0", driver: String = "U-0:A",
                         sink: String = "U-sink:B") -> ParasiticIR {
        let net = NetName(netName)
        let nodes = [ParasiticNode(name: NodeName(driver), kind: .pin, instancePath: nil, coordinate: nil),
                     ParasiticNode(name: NodeName(sink), kind: .pin, instancePath: nil, coordinate: nil),
                     ParasiticNode(name: NodeName("wire-node"), kind: .internal, instancePath: nil, coordinate: nil)]
            .sorted { $0.name.value < $1.name.value }
        let a = NodeRef(netName: net, nodeName: NodeName(driver))
        let b = NodeRef(netName: net, nodeName: NodeName(sink))
        let wire = NodeRef(netName: net, nodeName: NodeName("wire-node"))
        return ParasiticIR(version: ParasiticIR.currentVersion, cornerID: "tt", units: .canonical,
            nets: [.init(name: net, nodes: nodes, totalGroundCapF: 1e-12,
                         totalCouplingCapF: 0, totalResistanceOhm: 2)],
            elements: [.init(id: netName + "_C1", kind: .capacitor, nodeA: b, nodeB: nil, value: 1e-12, source: .extracted),
                       .init(id: netName + "_R1", kind: .resistor, nodeA: a, nodeB: wire, value: 0, source: .extracted),
                       .init(id: netName + "_R2", kind: .resistor, nodeA: wire, nodeB: b, value: 2, source: .extracted)],
            metadata: ["sourceFormat": "SPEF", "referenceNodeName": "0"])
    }

    private func canonical(_ ir: ParasiticIR) throws -> String {
        try SPEFWriter(options: .init(terminalTokenProfile: .canonical)).write(ir)
    }

    private func parse(_ text: String) throws -> ParasiticIR {
        var lexer = SPEFLexer(source: text)
        return try SPEFLowering().lower(SPEFParser().parse(tokens: lexer.tokenize()), cornerID: "tt")
    }

    @Test(arguments: ["net-0", "net-name", "net-01", "n-0e-3"])
    func canonicalGraphRoundTripsWithoutRenaming(_ name: String) throws {
        let ir = fixture(netName: name)
        let text = try canonical(ir)
        #expect(text.contains(name.replacingOccurrences(of: "-", with: "\\-")))
        #expect(text.contains("U\\-0:A") && text.contains("U\\-sink:B"))
        #expect(!text.contains("PEX_PIN_"))
        let restored = try parse(text)
        #expect(restored == ir)
        let zero = try #require(restored.elements.first { $0.kind == .resistor && $0.value == 0 })
        #expect(zero.nodeA == ir.elements[1].nodeA && zero.nodeB == ir.elements[1].nodeB)
    }

    @Test func escapedAndRawIntegerSuffixesPreserveNameMapIdentity() throws {
        for spelling in ["net-0", "net\\-0", "net\\-name"] {
            let text = """
            *SPEF "IEEE 1481-1998"
            *DESIGN "top"
            *DIVIDER /
            *DELIMITER :
            *BUS_DELIMITER [ ]
            *T_UNIT 1 NS
            *C_UNIT 1 PF
            *R_UNIT 1 OHM
            *NAME_MAP
            *1 \(spelling)
            *2 U\\-0:A
            *3 U\\-sink:B
            *D_NET *1 1
            *CONN
            *P *2 B
            *P *3 B
            *CAP
            1 *3 1
            *RES
            1 *2 *3 0
            *END
            """
            var lexer = SPEFLexer(source: text)
            let tree = try SPEFParser().parse(tokens: lexer.tokenize())
            #expect(tree.nameMap[1] == spelling.replacingOccurrences(of: "\\-", with: "-"))
            #expect(tree.nameMap[2] == "U-0:A" && tree.nameMap[3] == "U-sink:B")
            #expect(tree.nets[0].resistors[0].value == 0)
        }
    }

    @Test func numericSignsRemainValuesAndLetterHyphensRequireEscaping() {
        var lexer = SPEFLexer(source: "net-0 -1e-3 +2.5 U\\-sink:B")
        #expect(lexer.tokenize().map { $0.token } == [
            .identifier("net-0"), .number(-1e-3), .number(2.5), .identifier("U-sink:B"), .endOfFile])
        var unescaped = SPEFLexer(source: "net-name")
        #expect(unescaped.tokenize().contains { if case .invalid = $0.token { true } else { false } })
    }

    @Test func distinctHyphenNamesRetainCouplingAndZeroResistance() throws {
        let a = fixture(netName: "net-0"), b = fixture(netName: "net0", driver: "V0:A", sink: "V0:B")
        let coupling = ParasiticElement(id: "net-0_C2", kind: .coupling,
            nodeA: a.elements[0].nodeA, nodeB: b.elements[1].nodeA, value: 2e-12, source: .extracted)
        let first = a.nets[0]
        let ir = ParasiticIR(version: a.version, cornerID: a.cornerID, units: a.units,
            nets: [.init(name: first.name, nodes: first.nodes, totalGroundCapF: 1e-12,
                         totalCouplingCapF: 2e-12, totalResistanceOhm: 2), b.nets[0]],
            elements: [a.elements[0], coupling, a.elements[1], a.elements[2]] + b.elements,
            metadata: a.metadata)
        let restored = try parse(canonical(ir))
        #expect(restored == ir)
        #expect(restored.nets.map { $0.name.value } == ["net-0", "net0"])
        #expect(restored.elements.filter { $0.kind == .resistor && $0.value == 0 }.count == 2)
        #expect(restored.elements.first { $0.kind == .coupling } == coupling)
    }

    @Test func escapesCannotHideCollisionsOrAlterAnnotatedOwner() throws {
        #expect(throws: SPEFWriterError.self) { _ = try canonical(fixture(driver: "U\\-0:A")) }
        #expect(throws: SPEFWriterError.self) { _ = try canonical(fixture(driver: "net-0:3")) }
        let text = try canonical(fixture())
        let forged = text.replacingOccurrences(of: " net\\-0\n", with: " net\\-1\n")
        #expect(forged != text)
        #expect(throws: PEXError.self) { _ = try parse(forged) }
    }

    @Test func generatedProfileRetainsItsDialectAndExactGraph() throws {
        let ir = fixture()
        let text = try SPEFWriter().write(ir)
        #expect(text.contains("PEX_PIN_") && !text.contains("PEX_CANONICAL_TERMINALS_V1"))
        #expect(text.contains(" net\\-0\n"))
        #expect(try parse(text) == ir)
    }
}
