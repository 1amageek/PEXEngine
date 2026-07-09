import Foundation
import Testing
@testable import PEXCore
@testable import PEXParsers

@Suite("SPEF Writer Tests")
struct SPEFWriterTests {

    @Test func writesParseableSPEF() throws {
        let ir = makeIR()
        let writer = SPEFWriter(options: SPEFWriterOptions(designName: "top"))

        let spef = try writer.write(ir)

        #expect(spef.contains("*SPEF"))
        #expect(spef.contains("*DESIGN \"top\""))
        #expect(spef.contains("*D_NET VDD"))
        #expect(spef.contains("*N"))
        #expect(spef.contains("*CAP"))
        #expect(spef.contains("*RES"))
        #expect(spef.contains("*INDUC"))

        let lowered = try parseAndLower(spef)
        #expect(lowered.nets.count == 2)
        #expect(lowered.elements.contains { $0.kind == .coupling })
        #expect(lowered.elements.contains { $0.kind == .inductor })
    }

    @Test func roundTripsCanonicalValues() throws {
        let ir = makeIR()
        let spef = try SPEFWriter(options: SPEFWriterOptions(designName: "top")).write(ir)

        let lowered = try parseAndLower(spef)

        let groundCap = try #require(lowered.elements.first { $0.id == "VDD_C1" })
        let couplingCap = try #require(lowered.elements.first { $0.kind == .coupling })
        let resistor = try #require(lowered.elements.first { $0.kind == .resistor && $0.nodeA.netName == NetName("VDD") })
        let inductor = try #require(lowered.elements.first { $0.kind == .inductor && $0.nodeA.netName == NetName("VDD") })

        #expect(abs(groundCap.value - 0.2e-12) < 1e-18)
        #expect(abs(couplingCap.value - 0.05e-12) < 1e-18)
        #expect(abs(resistor.value - 10.0) < 1e-9)
        #expect(abs(inductor.value - 2.5e-9) < 1e-18)
        let vdd = try #require(lowered.nets.first { $0.name == NetName("VDD") })
        #expect(vdd.nodes.first { $0.name == NodeName("VDD:1") }?.coordinate == Point2D(x: 10, y: 20))
        #expect(vdd.nodes.first { $0.name == NodeName("VDD:2") }?.coordinate == Point2D(x: 11, y: 20))
    }

    @Test func writesNameMapForMagicPhysicalNodeNames() throws {
        let net = NetName("OUT")
        let firstNode = NodeName("m1_0_0#")
        let secondNode = NodeName("m1_1_0#")
        let ir = ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: [
                ParasiticNet(
                    name: net,
                    nodes: [
                        ParasiticNode(name: firstNode, kind: .internal, instancePath: nil, coordinate: nil),
                        ParasiticNode(name: secondNode, kind: .internal, instancePath: nil, coordinate: nil),
                    ],
                    totalGroundCapF: 1e-15,
                    totalCouplingCapF: 0,
                    totalResistanceOhm: 5
                ),
            ],
            elements: [
                ParasiticElement(
                    id: "Cphys",
                    kind: .capacitor,
                    nodeA: NodeRef(netName: net, nodeName: firstNode),
                    nodeB: nil,
                    value: 1e-15,
                    source: .extracted
                ),
                ParasiticElement(
                    id: "Rphys",
                    kind: .resistor,
                    nodeA: NodeRef(netName: net, nodeName: firstNode),
                    nodeB: NodeRef(netName: net, nodeName: secondNode),
                    value: 5,
                    source: .extracted
                ),
            ],
            metadata: ["designName": "phys"]
        )

        let spef = try SPEFWriter(options: SPEFWriterOptions(designName: "phys")).write(ir)

        #expect(spef.contains("*NAME_MAP"))
        #expect(spef.contains("m1_0_0#"))
        #expect(spef.contains("m1_1_0#"))
        #expect(spef.contains("*CAP"))
        #expect(spef.contains("*RES"))

        let lowered = try parseAndLower(spef)
        #expect(ParasiticIRValidator().validate(lowered).isValid)
        let loweredNet = try #require(lowered.nets.first { $0.name == net })
        #expect(Set(loweredNet.nodes.map(\.name)) == [firstNode, secondNode])
        #expect(lowered.elements.contains { $0.kind == .capacitor && $0.nodeA.nodeName == firstNode })
        #expect(lowered.elements.contains { $0.kind == .resistor && $0.nodeB?.nodeName == secondNode })
    }

    @Test func writesToFile() throws {
        let ir = makeIR()
        let url = FileManager.default.temporaryDirectory
            .appending(path: "writer_\(UUID().uuidString).spef")
        defer { removeTemporaryItem(url) }

        try SPEFWriter().write(ir, to: url)

        let data = try Data(contentsOf: url)
        #expect(!data.isEmpty)
    }

    @Test func rejectsInvalidIdentifier() {
        let badNet = ParasiticNet(
            name: NetName("bad net"),
            nodes: [],
            totalGroundCapF: 0,
            totalCouplingCapF: 0,
            totalResistanceOhm: 0
        )
        let ir = ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: [badNet],
            elements: [],
            metadata: [:]
        )

        #expect(throws: SPEFWriterError.self) {
            try SPEFWriter().write(ir)
        }
    }

    private func parseAndLower(_ spef: String) throws -> ParasiticIR {
        var lexer = SPEFLexer(source: spef)
        let tokens = lexer.tokenize()
        let tree = try SPEFParser().parse(tokens: tokens)
        return try SPEFLowering().lower(tree, cornerID: "tt")
    }

    private func makeIR() -> ParasiticIR {
        let vdd = NetName("VDD")
        let vss = NetName("VSS")
        let vdd1 = NodeName("VDD:1")
        let vdd2 = NodeName("VDD:2")
        let vss1 = NodeName("VSS:1")

        let nets = [
            ParasiticNet(
                name: vdd,
                nodes: [
                    ParasiticNode(name: vdd1, kind: .pin, instancePath: nil, coordinate: Point2D(x: 10, y: 20)),
                    ParasiticNode(name: vdd2, kind: .internal, instancePath: nil, coordinate: Point2D(x: 11, y: 20)),
                ],
                totalGroundCapF: 0.2e-12,
                totalCouplingCapF: 0.05e-12,
                totalResistanceOhm: 10
            ),
            ParasiticNet(
                name: vss,
                nodes: [
                    ParasiticNode(name: vss1, kind: .pin, instancePath: nil, coordinate: Point2D(x: 0, y: 0)),
                ],
                totalGroundCapF: 0.1e-12,
                totalCouplingCapF: 0,
                totalResistanceOhm: 0
            ),
        ]

        let elements = [
            ParasiticElement(
                id: "C1",
                kind: .capacitor,
                nodeA: NodeRef(netName: vdd, nodeName: vdd1),
                nodeB: nil,
                value: 0.2e-12,
                source: .extracted
            ),
            ParasiticElement(
                id: "CC1",
                kind: .coupling,
                nodeA: NodeRef(netName: vdd, nodeName: vdd1),
                nodeB: NodeRef(netName: vss, nodeName: vss1),
                value: 0.05e-12,
                source: .extracted
            ),
            ParasiticElement(
                id: "R1",
                kind: .resistor,
                nodeA: NodeRef(netName: vdd, nodeName: vdd1),
                nodeB: NodeRef(netName: vdd, nodeName: vdd2),
                value: 10,
                source: .extracted
            ),
            ParasiticElement(
                id: "L1",
                kind: .inductor,
                nodeA: NodeRef(netName: vdd, nodeName: vdd1),
                nodeB: NodeRef(netName: vdd, nodeName: vdd2),
                value: 2.5e-9,
                source: .extracted
            ),
        ]

        return ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: nets,
            elements: elements,
            metadata: ["designName": "top"]
        )
    }

    private func removeTemporaryItem(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
        }
    }
}
