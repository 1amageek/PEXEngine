import Foundation
import Testing
@testable import PEXCore
@testable import PEXParsers

@Suite("Scoped standard output identity")
struct ScopedStandardOutputTests {
    @Test func spicePreservesScopedGroundLikePinsCrossNetOperatorsAndReference() throws {
        let ir = fixture(crossResistance: true, reference: "SUBSTRATE")
        let text = try PEXSPICEWriter(options: .init(includeNodeMapComments: false)).write(ir)
        let lines = text.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        let resistor = try #require(lines.first { $0.first == "RPEX_Rcross" })
        #expect(resistor[1].lowercased() != resistor[2].lowercased())
        let declaration = try #require(lines.first { $0.first == ".subckt" })
        #expect(Set(declaration.dropFirst(2).map { $0.lowercased() }).count == declaration.count - 2)
        #expect(declaration.contains("PEX_REFERENCE_535542535452415445"))
        let restored = try parse(text, format: .spice)
        try expectGraph(ir, restored)
        #expect(restored.metadata["referenceNodeName"] == "SUBSTRATE")
        #expect(restored.elements.first { $0.kind == .resistor && $0.nodeA.netName != $0.nodeB?.netName }?.value == 10)
    }

    @Test func parserReadsActualSpiceValuesAndRejectsMissingIdentity() throws {
        let ir = fixture(crossResistance: true)
        let text = try PEXSPICEWriter().write(ir)
        let changed = text.replacingOccurrences(of: "1.000000000000e+01", with: "2.500000000000e+01")
        let restored = try parse(changed, format: .spice)
        #expect(restored.elements.first { $0.kind == .resistor && $0.nodeA.netName != $0.nodeB?.netName }?.value == 25)
        let stripped = text.split(separator: "\n").filter { !$0.hasPrefix(PEXSPICEIdentity.marker) }.joined(separator: "\n")
        #expect(throws: PEXError.self) { try parse(stripped, format: .spice) }
        let unknownEndpoint = text.replacingOccurrences(of: "RPEX_Rcross PEX_N_41_736861726564", with: "RPEX_Rcross unknown")
        #expect(throws: PEXError.self) { try parse(unknownEndpoint, format: .spice) }
    }

    @Test func spefRoundTripsRepeatedPinsQualifiedLeavesAndCrossNetCoupling() throws {
        let ir = fixture()
        let text = try SPEFWriter().write(ir)
        #expect(text.contains("PEX_IDENTITY_V1_"))
        let restored = try parse(text, format: .spef)
        try expectGraph(ir, restored)
        #expect(restored.nets.flatMap(\.nodes).filter { $0.name.value == "shared" && $0.kind == .pin }.count == 2)
        let coupling = try #require(restored.elements.first { $0.kind == .coupling })
        #expect(coupling.nodeA == NodeRef(netName: NetName("A"), nodeName: NodeName("shared")))
        #expect(coupling.nodeB == NodeRef(netName: NetName("B"), nodeName: NodeName("shared")))
    }

    @Test func spefReadsActualValuesAndRejectsUnmappedRecords() throws {
        let text = try SPEFWriter().write(fixture())
        let changed = text.replacingOccurrences(of: "2 PEX_PIN_41_30 0.003", with: "2 PEX_PIN_41_30 0.007")
        // Ground capacitance is read from the emitted CAP record, never the annotation.
        let restored = try parse(changed, format: .spef)
        #expect(abs((restored.elements.first { $0.kind == .capacitor }?.value ?? 0) - 7e-15) < 1e-25)
        let stripped = text.split(separator: "\n").filter { !$0.contains("PEX_IDENTITY_V1_") }.joined(separator: "\n")
        #expect(throws: PEXError.self) { try parse(stripped, format: .spef) }
    }

    @Test func spefPinlessCoordinatesDoNotCreateInvalidConnSection() throws {
        let name = NetName("floating")
        let ref = NodeRef(netName: name, nodeName: NodeName("leaf"))
        let ir = ParasiticIR(version: ParasiticIR.currentVersion, cornerID: "tt", units: .canonical,
            nets: [ParasiticNet(name: name, nodes: [ParasiticNode(name: ref.nodeName, kind: .internal,
                instancePath: nil, coordinate: Point2D(x: 1, y: 2))], totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0)],
            elements: [ParasiticElement(id: "C1", kind: .capacitor, nodeA: ref, nodeB: nil, value: 1e-15, source: .extracted)], metadata: [:])
        let text = try SPEFWriter().write(ir)
        #expect(!text.contains("*CONN"))
        let restored = try parse(text, format: .spef)
        try expectGraph(ir, restored)
        #expect(restored.nets.first?.nodes.first?.coordinate == nil)
    }

    @Test func spefPreservesCaseSensitiveNetScopesAndDeclaredUnits() throws {
        let names = [NetName("A"), NetName("a")]
        let nets = names.map { name in
            ParasiticNet(name: name, nodes: [ParasiticNode(name: NodeName("1"), kind: .internal, instancePath: nil, coordinate: nil)],
                         totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0)
        }
        let elements = names.enumerated().map { index, name in
            ParasiticElement(id: "C" + String(index), kind: .capacitor,
                             nodeA: NodeRef(netName: name, nodeName: NodeName("1")), nodeB: nil, value: 3, source: .extracted)
        }
        let ir = ParasiticIR(version: ParasiticIR.currentVersion, cornerID: "tt",
                            units: .init(resistance: .kiloOhm, capacitance: .picoFarad, coordinate: .micrometer),
                            nets: nets, elements: elements, metadata: [:])
        let restored = try parse(SPEFWriter().write(ir), format: .spef)
        #expect(Set(restored.nets.map(\.name)) == Set(names))
        #expect(restored.elements.allSatisfy { abs($0.value - 3e-12) < 1e-22 })
    }

    @Test func spefRejectsCrossNetResistanceAndNamedImplicitReference() throws {
        #expect(throws: SPEFWriterError.self) { try SPEFWriter().write(fixture(crossResistance: true)) }
        #expect(throws: SPEFWriterError.self) { try SPEFWriter().write(fixture(reference: "SUBSTRATE")) }
    }

    @Test func composerRejectsAmbiguousSourceLeafBindings() throws {
        let source = ".subckt TOP shared 0 gnd P p\nR1 shared gnd 1\n.ends TOP\n.end\n"
        #expect(throws: PEXSPICEBackannotationError.self) {
            try PEXSPICEBackannotationComposer(options: .init(topCell: "TOP")).compose(sourceNetlist: source, ir: fixture())
        }
    }

    private func fixture(crossResistance: Bool = false, reference: String = "0") -> ParasiticIR {
        let a = NetName("A")
        let b = NetName("B")
        let names = ["shared", "0", "gnd", "P", "p", "nested:leaf"]
        let nets = [a, b].map { net in
            ParasiticNet(name: net, nodes: names.map {
                ParasiticNode(name: NodeName($0), kind: $0 == "nested:leaf" ? .internal : .pin, instancePath: nil, coordinate: nil)
            }, totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0)
        }
        func ref(_ net: NetName, _ leaf: String) -> NodeRef { NodeRef(netName: net, nodeName: NodeName(leaf)) }
        var elements = [
            ParasiticElement(id: "Cground", kind: .capacitor, nodeA: ref(a, "0"), nodeB: nil, value: 3e-15, source: .extracted),
            ParasiticElement(id: "Ccross", kind: .coupling, nodeA: ref(a, "shared"), nodeB: ref(b, "shared"), value: 2e-15, source: .extracted),
            ParasiticElement(id: "Rlocal", kind: .resistor, nodeA: ref(a, "gnd"), nodeB: ref(a, "nested:leaf"), value: 4, source: .extracted),
            ParasiticElement(id: "Llocal", kind: .inductor, nodeA: ref(b, "P"), nodeB: ref(b, "p"), value: 1e-9, source: .extracted),
        ]
        if crossResistance {
            elements.append(ParasiticElement(id: "Rcross", kind: .resistor, nodeA: ref(a, "shared"), nodeB: ref(b, "shared"), value: 10, source: .extracted))
        }
        return ParasiticIR(version: ParasiticIR.currentVersion, cornerID: "tt", units: .canonical,
                           nets: nets, elements: elements, metadata: ["referenceNodeName": reference])
    }

    private func expectGraph(_ original: ParasiticIR, _ restored: ParasiticIR) throws {
        let originalNodes = Set(original.nets.flatMap { net in net.nodes.map { NodeRef(netName: net.name, nodeName: $0.name) } })
        let restoredNodes = Set(restored.nets.flatMap { net in net.nodes.map { NodeRef(netName: net.name, nodeName: $0.name) } })
        #expect(originalNodes == restoredNodes)
        #expect(original.elements.count == restored.elements.count)
        for element in original.elements {
            let actual = try #require(restored.elements.first { $0.kind == element.kind && $0.nodeA == element.nodeA && $0.nodeB == element.nodeB })
            #expect(abs(actual.value - element.value) <= abs(element.value) * 1e-10)
        }
    }

    private func parse(_ source: String, format: PEXOutputFormat) throws -> ParasiticIR {
        let url = FileManager.default.temporaryDirectory.appending(path: "scoped-standard-\(UUID().uuidString).\(format.rawValue)")
        try Data(source.utf8).write(to: url)
        defer {
            do { try FileManager.default.removeItem(at: url) }
            catch { Issue.record("Could not remove parser fixture: \(error)") }
        }
        let context = PEXParseContext(cornerID: "tt", runID: PEXRunID(), technology: nil, options: .default)
        let raw = PEXRawOutput(format: format, fileURLs: [url])
        switch format {
        case .spice: return try MagicSPICEParasiticParser().parse(raw, context: context)
        case .spef: return try SPEFPEXParser().parse(raw, context: context)
        default: throw PEXError.parseFailed(cornerID: "tt", message: "Unexpected test format")
        }
    }
}
