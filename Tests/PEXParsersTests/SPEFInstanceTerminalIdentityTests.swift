import Foundation
import Testing
import PEXCore
@testable import PEXParsers

@Suite("SPEF source instance terminal identity", .timeLimit(.minutes(1)))
struct SPEFInstanceTerminalIdentityTests {
    private func fixture(path: String = "U2", name: String = "U2:A") -> ParasiticIR {
        let net = NetName("signal")
        let port = NodeRef(netName: net, nodeName: NodeName("input"))
        let pin = NodeRef(netName: net, nodeName: NodeName(name))
        return .init(version: ParasiticIR.currentVersion, cornerID: "nominal", units: .canonical,
            nets: [.init(name: net, nodes: [
                .init(name: port.nodeName, kind: .pin, instancePath: nil, coordinate: .init(x: 1, y: 2)),
                .init(name: pin.nodeName, kind: .pin, instancePath: InstancePath(path), coordinate: .init(x: 1, y: 2))
            ], totalGroundCapF: 1e-15, totalCouplingCapF: 0, totalResistanceOhm: 0)],
            elements: [.init(id: "electrical-equivalence", kind: .resistor, nodeA: port, nodeB: pin, value: 0, source: .calculated),
                       .init(id: "wire-ground", kind: .capacitor, nodeA: pin, nodeB: nil, value: 1e-15, source: .calculated)], metadata: [:])
    }
    private func parse(_ source: String) throws -> ParasiticIR {
        var lexer = SPEFLexer(source: source)
        return try SPEFLowering().lower(SPEFParser().parse(tokens: lexer.tokenize()), cornerID: "nominal")
    }
    private func write(_ ir: ParasiticIR, canonical: Bool = true) throws -> String {
        try SPEFWriter(options: .init(terminalTokenProfile: canonical ? .canonical : .generatedScopedIdentity)).write(ir)
    }

    @Test(arguments: [false, true])
    func actualInstanceConnectionRestoresExactScopedPinAndZeroOhms(canonical: Bool) throws {
        let original = fixture()
        let source = try write(original, canonical: canonical)
        #expect(source.contains("*I "))
        #expect(source.contains("*P "))
        let reloaded = try parse(source)
        #expect(Set(reloaded.nets[0].nodes) == Set(original.nets[0].nodes))
        let actual = try #require(reloaded.elements.first { $0.kind == .resistor })
        let expected = original.elements[0]
        #expect(actual.nodeA == expected.nodeA && actual.nodeB == expected.nodeB && actual.value == 0)
        var lexer = SPEFLexer(source: source)
        let tree = try SPEFParser().parse(tokens: lexer.tokenize())
        #expect(tree.ports.count == 1)
        #expect(tree.nets[0].connections.filter { $0.type == .instancePin }.count == 1)
    }

    @Test func missingOrConflictingStandardRoleIsRefused() throws {
        let source = try write(fixture())
        for changed in [source.replacingOccurrences(of: "*I U2:A B", with: "*P U2:A B"),
                        source.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("*I U2:A B") }.joined(separator: "\n"),
                        source.replacingOccurrences(of: "*I U2:A B", with: "*I U2:A B\n*I U2:A B")] {
            #expect(throws: PEXError.self) { _ = try parse(changed) }
        }
    }

    @Test func forgedInstancePathCannotOverrideActualStandardPin() throws {
        let source = try write(fixture())
        let line = try #require(source.split(separator: "\n").first { $0.hasPrefix("*1 PEX_IDENTITY_V1_") })
        let annotation = String(line.dropFirst("*1 PEX_IDENTITY_V1_".count))
        var bytes = Data()
        var cursor = annotation.startIndex
        while cursor < annotation.endIndex {
            let end = annotation.index(cursor, offsetBy: 2)
            bytes.append(try #require(UInt8(annotation[cursor..<end], radix: 16)))
            cursor = end
        }
        let identity = try JSONDecoder().decode(PEXSPICEIdentity.self, from: bytes)
        var nodes = identity.nodes
        let old = try #require(nodes["U2:A"])
        nodes["U2:A"] = .init(ref: old.ref, kind: old.kind, instancePath: InstancePath("foreign"))
        let forged = PEXSPICEIdentity(nodes: nodes, elementKinds: identity.elementKinds,
            referenceName: identity.referenceName, referenceToken: identity.referenceToken,
            canonicalTerminals: identity.canonicalTerminals)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let replacement = "*1 PEX_IDENTITY_V1_" + (try encoder.encode(forged)).map { String(format: "%02x", $0) }.joined()
        #expect(throws: PEXError.self) { _ = try parse(source.replacingOccurrences(of: String(line), with: replacement)) }
    }

    @Test func generatedSPICEAnnotationCannotSupplyUncheckedInstancePath() throws {
        let source = try PEXSPICEWriter().write(fixture())
        let parsedIdentity = try PEXSPICEIdentity.read(source, cornerID: "nominal")
        let identity = try #require(parsedIdentity)
        var nodes = identity.nodes
        let token = try #require(nodes.first { $0.value.ref.nodeName == NodeName("U2:A") }?.key)
        let original = try #require(nodes[token])
        nodes[token] = .init(ref: original.ref, kind: original.kind, instancePath: InstancePath("foreign"))
        let forged = PEXSPICEIdentity(nodes: nodes, elementKinds: identity.elementKinds,
            referenceName: identity.referenceName, referenceToken: identity.referenceToken)
        let line = try #require(source.split(separator: "\n").first { $0.hasPrefix(PEXSPICEIdentity.marker) })
        let changed = source.replacingOccurrences(of: String(line), with: try forged.comment())
        let directory = FileManager.default.temporaryDirectory.appending(path: "spef-instance-boundary-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Temporary parser fixture cleanup failed: \(error)") }
        }
        let file = directory.appending(path: "generated.spice")
        try Data(changed.utf8).write(to: file)
        let restored = try MagicSPICEParasiticParser().parse(.init(format: .spice, fileURLs: [file]),
            context: .init(cornerID: "nominal", runID: .init(), technology: nil, options: .default))
        let pin = try #require(restored.nets[0].nodes.first { $0.name == NodeName("U2:A") })
        #expect(pin.instancePath == nil)
    }

    @Test func sourceNameAndInstancePathMustAgreeBeforeExport() throws {
        for ir in [fixture(path: "other"), fixture(path: ""), fixture(name: "U2:"), fixture(name: "U2:A:B")] {
            #expect(throws: SPEFWriterError.self) { _ = try write(ir) }
        }
    }
}
