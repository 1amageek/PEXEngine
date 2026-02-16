import Foundation
import PEXCore

public struct SPEFLowering: Sendable {
    public init() {}

    public func lower(_ tree: SPEFParseTree, cornerID: PEXCornerID) throws -> ParasiticIR {
        let (capScale, resScale) = unitScaleFactors(from: tree.header)
        let delimiter = tree.header.delimiter

        var nets: [ParasiticNet] = []
        var allElements: [ParasiticElement] = []

        for netBlock in tree.nets {
            let netName = NetName(resolveNameMap(netBlock.netName, nameMap: tree.nameMap))

            // Collect nodes from connections and element endpoints
            var nodeSet: Set<String> = []
            for conn in netBlock.connections {
                nodeSet.insert(resolveNameMap(conn.name, nameMap: tree.nameMap))
            }
            for cap in netBlock.capacitors {
                nodeSet.insert(resolveNameMap(cap.nodeA, nameMap: tree.nameMap))
                if let nodeB = cap.nodeB {
                    nodeSet.insert(resolveNameMap(nodeB, nameMap: tree.nameMap))
                }
            }
            for res in netBlock.resistors {
                nodeSet.insert(resolveNameMap(res.nodeA, nameMap: tree.nameMap))
                nodeSet.insert(resolveNameMap(res.nodeB, nameMap: tree.nameMap))
            }

            // Build node list
            let nodes = nodeSet.sorted().map { nodeName -> ParasiticNode in
                let kind: NodeKind = netBlock.connections.contains(where: {
                    resolveNameMap($0.name, nameMap: tree.nameMap) == nodeName
                }) ? .pin : .internal
                return ParasiticNode(
                    name: NodeName(nodeName),
                    kind: kind,
                    instancePath: nil,
                    coordinate: nil
                )
            }

            // Convert capacitors
            var totalGroundCap = 0.0
            var totalCouplingCap = 0.0
            for cap in netBlock.capacitors {
                let resolvedA = resolveNameMap(cap.nodeA, nameMap: tree.nameMap)
                let scaledValue = cap.value * capScale

                if let nodeB = cap.nodeB {
                    let resolvedB = resolveNameMap(nodeB, nameMap: tree.nameMap)
                    // Determine if coupling (cross-net) or internal
                    let isCrossNet = !nodeSet.contains(resolvedB)
                    let kind: ElementKind = isCrossNet ? .coupling : .capacitor

                    let element = ParasiticElement(
                        id: "\(netName.value)_C\(cap.id)",
                        kind: kind,
                        nodeA: NodeRef(netName: netName, nodeName: NodeName(resolvedA)),
                        nodeB: NodeRef(
                            netName: isCrossNet ? NetName(resolvedB.components(separatedBy: delimiter).first ?? resolvedB) : netName,
                            nodeName: NodeName(resolvedB)
                        ),
                        value: scaledValue,
                        source: .extracted
                    )
                    allElements.append(element)

                    if isCrossNet {
                        totalCouplingCap += scaledValue
                    }
                } else {
                    // Ground cap
                    let element = ParasiticElement(
                        id: "\(netName.value)_C\(cap.id)",
                        kind: .capacitor,
                        nodeA: NodeRef(netName: netName, nodeName: NodeName(resolvedA)),
                        nodeB: nil,
                        value: scaledValue,
                        source: .extracted
                    )
                    allElements.append(element)
                    totalGroundCap += scaledValue
                }
            }

            // Convert resistors
            var totalResistance = 0.0
            for res in netBlock.resistors {
                let resolvedA = resolveNameMap(res.nodeA, nameMap: tree.nameMap)
                let resolvedB = resolveNameMap(res.nodeB, nameMap: tree.nameMap)
                let scaledValue = res.value * resScale

                let element = ParasiticElement(
                    id: "\(netName.value)_R\(res.id)",
                    kind: .resistor,
                    nodeA: NodeRef(netName: netName, nodeName: NodeName(resolvedA)),
                    nodeB: NodeRef(netName: netName, nodeName: NodeName(resolvedB)),
                    value: scaledValue,
                    source: .extracted
                )
                allElements.append(element)
                totalResistance += scaledValue
            }

            let net = ParasiticNet(
                name: netName,
                nodes: nodes,
                totalGroundCapF: totalGroundCap,
                totalCouplingCapF: totalCouplingCap,
                totalResistanceOhm: totalResistance
            )
            nets.append(net)
        }

        return ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: cornerID,
            units: .canonical,
            nets: nets,
            elements: allElements,
            metadata: [
                "sourceFormat": "SPEF",
                "spefVersion": tree.header.spefVersion,
                "designName": tree.header.designName,
            ]
        )
    }

    /// Returns scale factors to convert header units to canonical (Farad, Ohm).
    /// Incorporates both the unit base (PF→1e-12) and the SPEF header scale factor (*C_UNIT 10 PF → 10).
    private func unitScaleFactors(from header: SPEFHeader) -> (cap: Double, res: Double) {
        let capBase: Double
        switch header.capUnit.uppercased() {
        case "PF": capBase = 1e-12
        case "FF": capBase = 1e-15
        case "NF": capBase = 1e-9
        case "F": capBase = 1.0
        default: capBase = 1e-12
        }

        let resBase: Double
        switch header.resUnit.uppercased() {
        case "OHM": resBase = 1.0
        case "KOHM": resBase = 1e3
        case "MOHM": resBase = 1e6
        default: resBase = 1.0
        }

        return (capBase * header.capScaleFactor, resBase * header.resScaleFactor)
    }

    /// Resolves mapped name references (*123 -> actual name).
    private func resolveNameMap(_ name: String, nameMap: [Int: String]) -> String {
        if name.hasPrefix("*"), let numStr = name.dropFirst().components(separatedBy: ":").first, let num = Int(numStr) {
            if let resolved = nameMap[num] {
                let suffix = name.dropFirst().drop(while: { $0 != ":" })
                return resolved + suffix
            }
        }
        return name
    }
}
