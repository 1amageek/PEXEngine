import Foundation
import PEXCore

struct MockParasiticGenerator: Sendable {
    let topCell: String
    let corner: PEXCorner
    let includeCouplingCaps: Bool

    init(topCell: String, corner: PEXCorner, includeCouplingCaps: Bool = true) {
        self.topCell = topCell
        self.corner = corner
        self.includeCouplingCaps = includeCouplingCaps
    }

    /// Temperature-based scaling factor for parasitic values.
    private var temperatureScale: Double {
        let baseTemp = 25.0
        let temp = corner.temperature ?? baseTemp
        return 1.0 + (temp - baseTemp) * 0.003
    }

    /// Generates a complete SPEF string for mock testing.
    func generateSPEF() -> String {
        let nets = mockNetNames()
        var lines: [String] = []

        // Header
        lines.append("*SPEF \"IEEE 1481-1998\"")
        lines.append("*DESIGN \"\(topCell)\"")
        lines.append("*DATE \"2024-01-01\"")
        lines.append("*VENDOR \"PEXEngine Mock\"")
        lines.append("*PROGRAM \"MockPEXAdapter\"")
        lines.append("*VERSION \"1.0\"")
        lines.append("*DESIGN_FLOW \"EXTERNAL\"")
        lines.append("*DIVIDER /")
        lines.append("*DELIMITER :")
        lines.append("*BUS_DELIMITER [ ]")
        lines.append("*T_UNIT 1 NS")
        lines.append("*C_UNIT 1 PF")
        lines.append("*R_UNIT 1 OHM")
        lines.append("*L_UNIT 1 HENRY")
        lines.append("")

        // Name map
        lines.append("*NAME_MAP")
        for (index, net) in nets.enumerated() {
            lines.append("*\(index + 1) \(net)")
        }
        lines.append("")

        // Ports
        lines.append("*PORTS")
        lines.append("\(nets[0]) I")
        if nets.count > 1 {
            lines.append("\(nets[nets.count - 1]) O")
        }
        lines.append("")

        // D_NET blocks
        for (netIndex, net) in nets.enumerated() {
            let baseCap = Double(netIndex + 1) * 0.05 * temperatureScale
            lines.append("*D_NET \(net) \(String(format: "%.6f", baseCap))")
            lines.append("*CONN")
            lines.append("*I \(topCell):\(net) I")
            lines.append("*CAP")

            // Ground cap
            let groundCap = baseCap * 0.7
            lines.append("1 \(net):1 \(String(format: "%.6f", groundCap))")

            // Internal cap
            let internalCap = baseCap * 0.3
            lines.append("2 \(net):1 \(net):2 \(String(format: "%.6f", internalCap))")

            // Coupling cap to adjacent net
            if includeCouplingCaps && netIndex + 1 < nets.count {
                let couplingCap = baseCap * 0.1
                lines.append("3 \(net):1 \(nets[netIndex + 1]):1 \(String(format: "%.6f", couplingCap))")
            }

            lines.append("*RES")
            let resistance = Double(netIndex + 1) * 10.0 * temperatureScale
            lines.append("1 \(net):1 \(net):2 \(String(format: "%.4f", resistance))")
            lines.append("*END")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Generates ParasiticIR directly (for fast test path, bypassing SPEF).
    func generateParasiticIR() -> ParasiticIR {
        let netNames = mockNetNames()
        var nets: [ParasiticNet] = []
        var allElements: [ParasiticElement] = []
        var elementCounter = 0

        for (netIndex, netNameStr) in netNames.enumerated() {
            let netName = NetName(netNameStr)
            let baseCap = Double(netIndex + 1) * 0.05e-12 * temperatureScale
            let baseRes = Double(netIndex + 1) * 10.0 * temperatureScale

            let node1 = ParasiticNode(
                name: NodeName("\(netNameStr):1"),
                kind: .pin,
                instancePath: InstancePath("\(topCell)/\(netNameStr)"),
                coordinate: Point2D(x: Double(netIndex) * 10.0, y: 0.0)
            )
            let node2 = ParasiticNode(
                name: NodeName("\(netNameStr):2"),
                kind: .internal,
                instancePath: nil,
                coordinate: Point2D(x: Double(netIndex) * 10.0 + 5.0, y: 0.0)
            )

            // Ground cap
            elementCounter += 1
            let groundCapElement = ParasiticElement(
                id: "C\(elementCounter)",
                kind: .capacitor,
                nodeA: NodeRef(netName: netName, nodeName: node1.name),
                nodeB: nil,
                value: baseCap * 0.7,
                source: .extracted
            )
            allElements.append(groundCapElement)

            // Internal cap
            elementCounter += 1
            let internalCapElement = ParasiticElement(
                id: "C\(elementCounter)",
                kind: .capacitor,
                nodeA: NodeRef(netName: netName, nodeName: node1.name),
                nodeB: NodeRef(netName: netName, nodeName: node2.name),
                value: baseCap * 0.3,
                source: .extracted
            )
            allElements.append(internalCapElement)

            // Coupling cap
            if includeCouplingCaps && netIndex + 1 < netNames.count {
                elementCounter += 1
                let nextNetName = NetName(netNames[netIndex + 1])
                let couplingElement = ParasiticElement(
                    id: "CC\(elementCounter)",
                    kind: .coupling,
                    nodeA: NodeRef(netName: netName, nodeName: node1.name),
                    nodeB: NodeRef(netName: nextNetName, nodeName: NodeName("\(netNames[netIndex + 1]):1")),
                    value: baseCap * 0.1,
                    source: .extracted
                )
                allElements.append(couplingElement)
            }

            // Resistor
            elementCounter += 1
            let resistorElement = ParasiticElement(
                id: "R\(elementCounter)",
                kind: .resistor,
                nodeA: NodeRef(netName: netName, nodeName: node1.name),
                nodeB: NodeRef(netName: netName, nodeName: node2.name),
                value: baseRes,
                source: .extracted
            )
            allElements.append(resistorElement)

            let groundCapF = baseCap * 0.7
            let couplingCapF = includeCouplingCaps && netIndex + 1 < netNames.count ? baseCap * 0.1 : 0.0

            let net = ParasiticNet(
                name: netName,
                nodes: [node1, node2],
                totalGroundCapF: groundCapF,
                totalCouplingCapF: couplingCapF,
                totalResistanceOhm: baseRes
            )
            nets.append(net)
        }

        return ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: corner.id,
            units: .canonical,
            nets: nets,
            elements: allElements,
            metadata: [
                "generator": "MockPEXAdapter",
                "topCell": topCell,
                "corner": corner.id.value,
            ]
        )
    }

    private func mockNetNames() -> [String] {
        ["VDD", "VSS", "clk", "data_in", "data_out", "net1", "net2", "net3", "net4", "net5"]
    }
}
