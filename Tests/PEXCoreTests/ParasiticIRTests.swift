import Testing
import Foundation
@testable import PEXCore

@Suite("ParasiticIR Tests")
struct ParasiticIRTests {
    @Test func codableRoundTrip() throws {
        let ir = makeTestIR()
        let encoder = JSONEncoder()
        let data = try encoder.encode(ir)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ParasiticIR.self, from: data)
        #expect(decoded.version == ir.version)
        #expect(decoded.cornerID == ir.cornerID)
        #expect(decoded.nets.count == ir.nets.count)
        #expect(decoded.elements.count == ir.elements.count)
    }

    @Test func currentVersion() {
        #expect(ParasiticIR.currentVersion == "1.0")
    }

    @Test func elementKinds() {
        #expect(ElementKind.resistor.rawValue == "resistor")
        #expect(ElementKind.capacitor.rawValue == "capacitor")
        #expect(ElementKind.coupling.rawValue == "coupling")
    }

    private func makeTestIR() -> ParasiticIR {
        let net = ParasiticNet(
            name: NetName("VDD"),
            nodes: [
                ParasiticNode(name: NodeName("VDD:1"), kind: .pin, instancePath: nil, coordinate: nil),
                ParasiticNode(name: NodeName("VDD:2"), kind: .internal, instancePath: nil, coordinate: nil),
            ],
            totalGroundCapF: 1e-12,
            totalCouplingCapF: 0.5e-12,
            totalResistanceOhm: 10.0
        )
        let elements: [ParasiticElement] = [
            ParasiticElement(
                id: "R1", kind: .resistor,
                nodeA: NodeRef(netName: NetName("VDD"), nodeName: NodeName("VDD:1")),
                nodeB: NodeRef(netName: NetName("VDD"), nodeName: NodeName("VDD:2")),
                value: 10.0, source: .extracted
            ),
            ParasiticElement(
                id: "C1", kind: .capacitor,
                nodeA: NodeRef(netName: NetName("VDD"), nodeName: NodeName("VDD:1")),
                nodeB: nil,
                value: 1e-12, source: .extracted
            ),
        ]
        return ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: PEXCornerID("tt"),
            units: .canonical,
            nets: [net],
            elements: elements,
            metadata: ["test": "true"]
        )
    }
}
