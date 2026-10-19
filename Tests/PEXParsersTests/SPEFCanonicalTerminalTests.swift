import Foundation
import Testing
@testable import PEXCore
@testable import PEXParsers

@Suite("Canonical standard SPEF terminals", .timeLimit(.minutes(1)))
struct SPEFCanonicalTerminalTests {
    private func fixture(_ pins: [String] = ["U:Y", "G/A$1"], internalName: String? = nil, netName: String = "n") -> ParasiticIR {
        let net = NetName(netName)
        let nodes = pins.map { ParasiticNode(name: NodeName($0), kind: .pin, instancePath: nil, coordinate: nil) }
            + (internalName.map { [ParasiticNode(name: NodeName($0), kind: .internal, instancePath: nil, coordinate: nil)] } ?? [])
        let refs = nodes.map { NodeRef(netName: net, nodeName: $0.name) }
        return ParasiticIR(version: ParasiticIR.currentVersion, cornerID: "tt", units: .canonical,
            nets: [.init(name: net, nodes: nodes, totalGroundCapF: 1e-15, totalCouplingCapF: 0, totalResistanceOhm: 0)],
            elements: [.init(id: "Rzero", kind: .resistor, nodeA: refs[0], nodeB: refs[1], value: 0, source: .calculated),
                       .init(id: "Cground", kind: .capacitor, nodeA: refs[1], nodeB: nil, value: 1e-15, source: .calculated)], metadata: [:])
    }
    private func parse(_ text: String) throws -> ParasiticIR {
        var lexer = SPEFLexer(source: text)
        return try SPEFLowering().lower(SPEFParser().parse(tokens: lexer.tokenize()), cornerID: "tt")
    }
    private func canonical(_ ir: ParasiticIR) throws -> String {
        try SPEFWriter(options: .init(terminalTokenProfile: .canonical)).write(ir)
    }
    private func identityBytes(_ text: String) throws -> Data {
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("*1 PEX_IDENTITY_V1_") })
        let hex = line.dropFirst("*1 PEX_IDENTITY_V1_".count)
        var bytes = Data(), cursor = hex.startIndex
        while cursor < hex.endIndex {
            let end = hex.index(cursor, offsetBy: 2)
            bytes.append(try #require(UInt8(hex[cursor..<end], radix: 16))); cursor = end
        }
        return bytes
    }

    @Test func actualTokensAndAnnotationRestoreExactTerminalNamesAndZeroResistance() throws {
        let ir = fixture()
        let text = try canonical(ir)
        #expect(text.contains("PEX_CANONICAL_TERMINALS_V1 PEX_IDENTITY_V1"))
        #expect(text.contains("*P U:Y B") && text.contains("G/A$1") && !text.contains("PEX_PIN_"))
        let restored = try parse(text)
        #expect(Set(restored.nets[0].nodes.map(\.name)) == Set(ir.nets[0].nodes.map(\.name)))
        let resistor = try #require(restored.elements.first { $0.kind == .resistor })
        #expect(resistor.value == 0 && resistor.nodeA == ir.elements[0].nodeA && resistor.nodeB == ir.elements[0].nodeB)
        let defaultText = try SPEFWriter().write(ir)
        #expect(defaultText.contains("PEX_PIN_") && !defaultText.contains("PEX_CANONICAL_TERMINALS_V1"))
        #expect(try parse(defaultText).elements.count == ir.elements.count)
        let canonicalIdentity = try #require(JSONSerialization.jsonObject(with: identityBytes(text)) as? [String: Any])
        let defaultIdentity = try #require(JSONSerialization.jsonObject(with: identityBytes(defaultText)) as? [String: Any])
        #expect(canonicalIdentity["canonicalTerminals"] as? Bool == true)
        #expect(defaultIdentity["canonicalTerminals"] == nil)
    }

    @Test func canonicalCollisionsAndAmbiguousEscapingRefuse() throws {
        for pins in [["0", "sink"], ["bad\\name", "sink"], ["white space", "sink"],
                     ["01", "sink"], ["/pin", "sink"], [":pin", "sink"], ["[pin]", "sink"], ["PEX_IDENTITY_V1_aa$", "sink"]] {
            #expect(throws: SPEFWriterError.self) { _ = try canonical(fixture(pins)) }
        }
        #expect(throws: SPEFWriterError.self) { _ = try canonical(fixture(["n:1", "sink"], internalName: "leaf")) }
        #expect(throws: SPEFWriterError.self) { _ = try canonical(fixture(netName: "01")) }
        let a = fixture(["shared", "a"], netName: "A"), b = fixture(["shared", "b"], netName: "B")
        let both = ParasiticIR(version: ParasiticIR.currentVersion, cornerID: "tt", units: .canonical,
            nets: a.nets + b.nets, elements: a.elements.enumerated().map { index, element in
                .init(id: "A" + String(index), kind: element.kind, nodeA: element.nodeA, nodeB: element.nodeB, value: element.value, source: element.source)
            } + b.elements.enumerated().map { index, element in
                .init(id: "B" + String(index), kind: element.kind, nodeA: element.nodeA, nodeB: element.nodeB, value: element.value, source: element.source)
            }, metadata: [:])
        #expect(throws: SPEFWriterError.self) { _ = try canonical(both) }
        #expect(try SPEFWriter().write(both).contains("PEX_PIN_"))
    }

    @Test func sameOwnerTopPortAndNetRootShareOneCanonicalToken() throws {
        let ir = fixture(["a", "U1:A"], netName: "a")
        let text = try canonical(ir)
        #expect(text.contains("*D_NET a ") && text.contains("*P a B") && text.contains("*P U1:A B"))
        #expect(text.contains("1 a U1:A 0"))
        let restored = try parse(text)
        #expect(restored.nets.count == 1 && restored.nets[0].name.value == "a")
        #expect(Set(restored.nets[0].nodes.map(\.name)) == Set(ir.nets[0].nodes.map(\.name)))
        let resistor = try #require(restored.elements.first { $0.kind == .resistor })
        #expect(resistor.nodeA == ir.elements[0].nodeA && resistor.nodeB == ir.elements[0].nodeB && resistor.value == 0)

        let foreign = fixture(["B", "sinkA"], netName: "A"), other = fixture(["sourceB", "sinkB"], netName: "B")
        let both = ParasiticIR(version: ParasiticIR.currentVersion, cornerID: "tt", units: .canonical,
            nets: foreign.nets + other.nets, elements: foreign.elements + other.elements.map {
                .init(id: "B" + $0.id, kind: $0.kind, nodeA: $0.nodeA, nodeB: $0.nodeB, value: $0.value, source: $0.source)
            }, metadata: [:])
        #expect(throws: SPEFWriterError.self) { _ = try canonical(both) }
    }

    @Test func forgedMissingDuplicateAndConflictingAnnotationsCannotRestoreIdentity() throws {
        let text = try canonical(fixture(["U:Y", "G:A"]))
        let prefix = "PEX_IDENTITY_V1_"
        let annotationLine = try #require(text.split(separator: "\n").first { $0.hasPrefix("*1 " + prefix) })
        let bytes = try identityBytes(text)
        var identity = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var nodes = try #require(identity["nodes"] as? [String: Any])
        var node = try #require(nodes["U:Y"] as? [String: Any])
        var ref = try #require(node["ref"] as? [String: Any])
        ref["nodeName"] = ["value": "forged"]; node["ref"] = ref; nodes["U:Y"] = node; identity["nodes"] = nodes
        let forged = prefix + (try JSONSerialization.data(withJSONObject: identity, options: .sortedKeys)).map { String(format: "%02x", $0) }.joined()
        #expect(throws: PEXError.self) { _ = try parse(text.replacingOccurrences(of: String(annotationLine), with: "*1 " + forged)) }
        #expect(throws: PEXError.self) { _ = try parse(text.replacingOccurrences(of: String(annotationLine) + "\n", with: "")) }
        #expect(throws: PEXError.self) { _ = try parse(text.replacingOccurrences(of: String(annotationLine), with: String(annotationLine) + "\n*999 " + String(annotationLine.dropFirst(3)))) }
        #expect(throws: PEXError.self) { _ = try parse(text.replacingOccurrences(of: "*P U:Y B", with: "*P foreign B")) }
        #expect(throws: PEXError.self) { _ = try parse(text.replacingOccurrences(of: " PEX_IDENTITY_V1\"", with: "\"")) }
        let forgedText = text.replacingOccurrences(of: String(annotationLine), with: "*1 " + forged)
        #expect(throws: PEXError.self) { _ = try parse(forgedText.replacingOccurrences(of: " PEX_CANONICAL_TERMINALS_V1", with: "")) }
        #expect(throws: PEXError.self) { _ = try parse(text.replacingOccurrences(of: " PEX_CANONICAL_TERMINALS_V1 PEX_IDENTITY_V1", with: "")) }
        #expect(throws: SPEFParserDiagnostic.self) { _ = try parse(text.replacingOccurrences(of: String(annotationLine), with: String(annotationLine) + "\n" + String(annotationLine))) }
        #expect(throws: SPEFParserDiagnostic.self) { _ = try parse(text.replacingOccurrences(of: String(annotationLine), with: String(annotationLine) + "\n*1 conflicting")) }
    }
}
