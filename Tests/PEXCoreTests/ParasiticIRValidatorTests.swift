import Testing
@testable import PEXCore

@Suite("ParasiticIR Validator Tests")
struct ParasiticIRValidatorTests {
    let validator = ParasiticIRValidator()

    @Test func validIRPasses() {
        let ir = makeValidIR()
        let result = validator.validate(ir)
        #expect(result.isValid)
        #expect(result.errors.isEmpty)
    }

    @Test func duplicateElementIDDetected() {
        let net = ParasiticNet(
            name: NetName("net1"),
            nodes: [ParasiticNode(name: NodeName("n1"), kind: .pin, instancePath: nil, coordinate: nil)],
            totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0
        )
        let elements = [
            ParasiticElement(id: "R1", kind: .resistor,
                nodeA: NodeRef(netName: NetName("net1"), nodeName: NodeName("n1")),
                nodeB: NodeRef(netName: NetName("net1"), nodeName: NodeName("n1")),
                value: 100, source: .extracted),
            ParasiticElement(id: "R1", kind: .resistor,
                nodeA: NodeRef(netName: NetName("net1"), nodeName: NodeName("n1")),
                nodeB: NodeRef(netName: NetName("net1"), nodeName: NodeName("n1")),
                value: 200, source: .extracted),
        ]
        let ir = ParasiticIR(version: "1.0", cornerID: "tt", units: .canonical, nets: [net], elements: elements, metadata: [:])
        let result = validator.validate(ir)
        #expect(!result.isValid)
        #expect(result.errors.contains(where: { if case .duplicateElementID("R1") = $0 { return true }; return false }))
    }

    @Test func danglingNodeReferenceDetected() {
        let net = ParasiticNet(
            name: NetName("net1"),
            nodes: [ParasiticNode(name: NodeName("n1"), kind: .pin, instancePath: nil, coordinate: nil)],
            totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0
        )
        let elements = [
            ParasiticElement(id: "R1", kind: .resistor,
                nodeA: NodeRef(netName: NetName("net1"), nodeName: NodeName("n1")),
                nodeB: NodeRef(netName: NetName("net1"), nodeName: NodeName("n_nonexistent")),
                value: 100, source: .extracted),
        ]
        let ir = ParasiticIR(version: "1.0", cornerID: "tt", units: .canonical, nets: [net], elements: elements, metadata: [:])
        let result = validator.validate(ir)
        #expect(!result.isValid)
        #expect(result.errors.contains(where: { if case .danglingNodeReference(_, "n_nonexistent") = $0 { return true }; return false }))
    }

    @Test func negativeValueDetected() {
        let net = ParasiticNet(
            name: NetName("net1"),
            nodes: [ParasiticNode(name: NodeName("n1"), kind: .pin, instancePath: nil, coordinate: nil)],
            totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0
        )
        let elements = [
            ParasiticElement(id: "R1", kind: .resistor,
                nodeA: NodeRef(netName: NetName("net1"), nodeName: NodeName("n1")),
                nodeB: nil,
                value: -5.0, source: .extracted),
        ]
        let ir = ParasiticIR(version: "1.0", cornerID: "tt", units: .canonical, nets: [net], elements: elements, metadata: [:])
        let result = validator.validate(ir)
        #expect(!result.isValid)
    }

    @Test func emptyNetWarning() {
        let net = ParasiticNet(
            name: NetName("empty_net"),
            nodes: [],
            totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0
        )
        let ir = ParasiticIR(version: "1.0", cornerID: "tt", units: .canonical, nets: [net], elements: [], metadata: [:])
        let result = validator.validate(ir)
        #expect(result.isValid)
        #expect(result.warnings.contains(where: { if case .emptyNet("empty_net") = $0 { return true }; return false }))
    }

    private func makeValidIR() -> ParasiticIR {
        let net = ParasiticNet(
            name: NetName("net1"),
            nodes: [
                ParasiticNode(name: NodeName("n1"), kind: .pin, instancePath: nil, coordinate: nil),
                ParasiticNode(name: NodeName("n2"), kind: .internal, instancePath: nil, coordinate: nil),
            ],
            totalGroundCapF: 1e-12, totalCouplingCapF: 0, totalResistanceOhm: 100
        )
        let elements = [
            ParasiticElement(id: "R1", kind: .resistor,
                nodeA: NodeRef(netName: NetName("net1"), nodeName: NodeName("n1")),
                nodeB: NodeRef(netName: NetName("net1"), nodeName: NodeName("n2")),
                value: 100, source: .extracted),
            ParasiticElement(id: "C1", kind: .capacitor,
                nodeA: NodeRef(netName: NetName("net1"), nodeName: NodeName("n1")),
                nodeB: nil,
                value: 1e-12, source: .extracted),
        ]
        return ParasiticIR(version: "1.0", cornerID: "tt", units: .canonical, nets: [net], elements: elements, metadata: [:])
    }
}
