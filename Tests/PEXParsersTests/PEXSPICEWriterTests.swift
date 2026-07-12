import Foundation
import Testing
@testable import PEXCore
@testable import PEXParsers

@Suite("PEX SPICE Backannotation Writer Tests")
struct PEXSPICEWriterTests {
    @Test func composesBackannotationIntoSelectedSubcircuit() throws {
        let source = """
        .subckt TOP VDD VSS
        Rbase VDD VSS 1k
        .ends TOP
        V1 VDD 0 1
        XTOP VDD VSS TOP
        .end
        """

        let composed = try PEXSPICEBackannotationComposer(
            options: PEXSPICEBackannotationOptions(topCell: "TOP")
        ).compose(sourceNetlist: source, ir: makeComposableIR())

        #expect(composed.contains("XPEX_tt VDD VSS PEX_TOP_tt"))
        #expect(composed.contains(".subckt PEX_TOP_tt vdd vss"))
        #expect(composed.contains("RPEX_Rsegment vdd"))
        #expect(composed.split(separator: "\n").filter { $0.lowercased() == ".end" }.count == 1)
        #expect(composed.range(of: "XPEX_tt VDD VSS PEX_TOP_tt")!.lowerBound < composed.range(of: ".ends TOP")!.lowerBound)
    }

    @Test func composerResolvesInstanceNameCollisionAndRejectsUnmatchedPort() throws {
        let source = """
        .subckt TOP VDD VSS
        Rbase VDD VSS 1k
        .ends TOP
        XPEX_tt VDD VSS TOP
        .end
        """
        let composed = try PEXSPICEBackannotationComposer(
            options: PEXSPICEBackannotationOptions(topCell: "TOP")
        ).compose(sourceNetlist: source, ir: makeComposableIR())
        #expect(composed.contains("XPEX_tt_2 VDD VSS PEX_TOP_tt"))

        let unmatchedIR = ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: [ParasiticNet(
                name: NetName("OUT"),
                nodes: [ParasiticNode(name: NodeName("missing"), kind: .pin, instancePath: nil, coordinate: nil)],
                totalGroundCapF: 0,
                totalCouplingCapF: 0,
                totalResistanceOhm: 0
            )],
            elements: [ParasiticElement(
                id: "Cmissing",
                kind: .capacitor,
                nodeA: NodeRef(netName: NetName("OUT"), nodeName: NodeName("missing")),
                nodeB: nil,
                value: 1e-15,
                source: .extracted
            )],
            metadata: ["topCell": "TOP"]
        )
        #expect(throws: PEXSPICEBackannotationError.unmatchedSourcePort("missing")) {
            try PEXSPICEBackannotationComposer(
                options: PEXSPICEBackannotationOptions(topCell: "TOP")
            ).compose(sourceNetlist: source, ir: unmatchedIR)
        }
    }

    @Test func writesAllCanonicalElementKindsAndGroundCapacitance() throws {
        let vdd = NetName("VDD")
        let vss = NetName("VSS")
        let vddPin = NodeName("vdd")
        let shared = NodeName("n1")
        let vssPin = NodeName("vss")
        let ir = ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: ParasiticUnits(resistance: .kiloOhm, capacitance: .picoFarad, coordinate: .micrometer),
            nets: [
                ParasiticNet(
                    name: vdd,
                    nodes: [
                        ParasiticNode(name: vddPin, kind: .pin, instancePath: nil, coordinate: nil),
                        ParasiticNode(name: shared, kind: .internal, instancePath: nil, coordinate: nil),
                    ],
                    totalGroundCapF: 1,
                    totalCouplingCapF: 0,
                    totalResistanceOhm: 0
                ),
                ParasiticNet(
                    name: vss,
                    nodes: [
                        ParasiticNode(name: vssPin, kind: .pin, instancePath: nil, coordinate: nil),
                        ParasiticNode(name: shared, kind: .internal, instancePath: nil, coordinate: nil),
                    ],
                    totalGroundCapF: 0,
                    totalCouplingCapF: 0,
                    totalResistanceOhm: 0
                ),
            ],
            elements: [
                ParasiticElement(
                    id: "Cground",
                    kind: .capacitor,
                    nodeA: NodeRef(netName: vdd, nodeName: vddPin),
                    nodeB: nil,
                    value: 2,
                    source: .extracted
                ),
                ParasiticElement(
                    id: "Ccouple",
                    kind: .coupling,
                    nodeA: NodeRef(netName: vdd, nodeName: shared),
                    nodeB: NodeRef(netName: vss, nodeName: shared),
                    value: 3,
                    source: .extracted
                ),
                ParasiticElement(
                    id: "Rsegment",
                    kind: .resistor,
                    nodeA: NodeRef(netName: vdd, nodeName: vddPin),
                    nodeB: NodeRef(netName: vdd, nodeName: shared),
                    value: 4,
                    source: .extracted
                ),
                ParasiticElement(
                    id: "Lsegment",
                    kind: .inductor,
                    nodeA: NodeRef(netName: vss, nodeName: vssPin),
                    nodeB: NodeRef(netName: vss, nodeName: shared),
                    value: 5e-9,
                    source: .extracted
                ),
            ],
            metadata: ["topCell": "TOP"]
        )

        let spice = try PEXSPICEWriter().write(ir)

        #expect(spice.contains(".subckt PEX_TOP_tt vdd vss"))
        #expect(spice.contains("CPEX_Cground vdd 0 2.000000000000e-12"))
        #expect(spice.contains("CPEX_Ccouple"))
        #expect(spice.contains("RPEX_Rsegment vdd"))
        #expect(spice.contains("LPEX_Lsegment vss"))
        #expect(spice.contains("PEX_NODE_MAP"))
        #expect(spice.contains(".ends PEX_TOP_tt"))
    }

    @Test func rejectsMissingEndpointAndNonFiniteValues() {
        let net = NetName("N")
        let node = NodeName("n")
        let base = ParasiticNet(
            name: net,
            nodes: [ParasiticNode(name: node, kind: .internal, instancePath: nil, coordinate: nil)],
            totalGroundCapF: 0,
            totalCouplingCapF: 0,
            totalResistanceOhm: 0
        )

        let missingEndpoint = ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: [base],
            elements: [ParasiticElement(
                id: "Rbad",
                kind: .resistor,
                nodeA: NodeRef(netName: net, nodeName: node),
                nodeB: nil,
                value: 1,
                source: .extracted
            )],
            metadata: [:]
        )
        #expect(throws: PEXSPICEWriterError.missingEndpoint("Rbad")) {
            try PEXSPICEWriter().write(missingEndpoint)
        }

        let nonFinite = ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: [base],
            elements: [ParasiticElement(
                id: "Cbad",
                kind: .capacitor,
                nodeA: NodeRef(netName: net, nodeName: node),
                nodeB: nil,
                value: .infinity,
                source: .extracted
            )],
            metadata: [:]
        )
        #expect(throws: PEXSPICEWriterError.nonFiniteValue("Cbad")) {
            try PEXSPICEWriter().write(nonFinite)
        }
    }

    private func makeComposableIR() -> ParasiticIR {
        let vdd = NetName("VDD")
        let vss = NetName("VSS")
        let vddPin = NodeName("vdd")
        let vssPin = NodeName("vss")
        let internalNode = NodeName("n1")
        return ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: [
                ParasiticNet(
                    name: vdd,
                    nodes: [
                        ParasiticNode(name: vddPin, kind: .pin, instancePath: nil, coordinate: nil),
                        ParasiticNode(name: internalNode, kind: .internal, instancePath: nil, coordinate: nil),
                    ],
                    totalGroundCapF: 0,
                    totalCouplingCapF: 0,
                    totalResistanceOhm: 0
                ),
                ParasiticNet(
                    name: vss,
                    nodes: [
                        ParasiticNode(name: vssPin, kind: .pin, instancePath: nil, coordinate: nil),
                    ],
                    totalGroundCapF: 0,
                    totalCouplingCapF: 0,
                    totalResistanceOhm: 0
                ),
            ],
            elements: [
                ParasiticElement(
                    id: "Rsegment",
                    kind: .resistor,
                    nodeA: NodeRef(netName: vdd, nodeName: vddPin),
                    nodeB: NodeRef(netName: vdd, nodeName: internalNode),
                    value: 2,
                    source: .extracted
                ),
                ParasiticElement(
                    id: "Cground",
                    kind: .capacitor,
                    nodeA: NodeRef(netName: vss, nodeName: vssPin),
                    nodeB: nil,
                    value: 1e-15,
                    source: .extracted
                ),
            ],
            metadata: ["topCell": "TOP"]
        )
    }
}
