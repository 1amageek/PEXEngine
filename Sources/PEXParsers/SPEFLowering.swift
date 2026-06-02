import Foundation
import PEXCore

public struct SPEFLowering: Sendable {
    public init() {}

    public func lower(_ tree: SPEFParseTree, cornerID: PEXCornerID) throws -> ParasiticIR {
        let (capScale, resScale) = unitScaleFactors(from: tree.header)
        let delimiter = tree.header.delimiter
        let explicitNodeOwners = explicitNodeOwnerMap(from: tree)
        let portNames = Set(tree.ports.map { resolveNameMap($0.name, nameMap: tree.nameMap) })

        var nets: [ParasiticNet] = []
        var allElements: [ParasiticElement] = []
        var externalNodesByNet: [NetName: Set<String>] = [:]
        // Tracks coupling caps already emitted, keyed by their unordered
        // resolved-node pair. IEEE 1481 SPEF lists a coupling reciprocally in
        // both coupled nets' *CAP sections, so the same physical cap is seen
        // twice during the per-net walk; without this it would be counted twice.
        var seenCouplingValues: [String: Double] = [:]

        for netBlock in tree.nets {
            let netName = NetName(resolveNameMap(netBlock.netName, nameMap: tree.nameMap))
            let localNodeSet = localNodes(in: netBlock, nameMap: tree.nameMap)

            // Collect nodes from connections and element endpoints
            var nodeSet: Set<String> = []
            for conn in netBlock.connections {
                nodeSet.insert(resolveNameMap(conn.name, nameMap: tree.nameMap))
            }
            for cap in netBlock.capacitors {
                let resolvedA = resolveNameMap(cap.nodeA, nameMap: tree.nameMap)
                if let nodeB = cap.nodeB {
                    let resolvedB = resolveNameMap(nodeB, nameMap: tree.nameMap)
                    let localA = isLocalNode(resolvedA, netName: netName, localNodeSet: localNodeSet, explicitNodeOwners: explicitNodeOwners)
                    let localB = isLocalNode(resolvedB, netName: netName, localNodeSet: localNodeSet, explicitNodeOwners: explicitNodeOwners)
                    if localA || !localB {
                        nodeSet.insert(resolvedA)
                    }
                    if localB {
                        nodeSet.insert(resolvedB)
                    }
                } else {
                    nodeSet.insert(resolvedA)
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
                    let localA = isLocalNode(resolvedA, netName: netName, localNodeSet: localNodeSet, explicitNodeOwners: explicitNodeOwners)
                    let localB = isLocalNode(resolvedB, netName: netName, localNodeSet: localNodeSet, explicitNodeOwners: explicitNodeOwners)
                    let localNode: String
                    let remoteNode: String?
                    if localA && !localB {
                        localNode = resolvedA
                        remoteNode = resolvedB
                    } else if localB && !localA {
                        localNode = resolvedB
                        remoteNode = resolvedA
                    } else {
                        localNode = resolvedA
                        remoteNode = localA && localB ? nil : resolvedB
                    }
                    let kind: ElementKind = remoteNode == nil ? .capacitor : .coupling

                    // Count each physical coupling cap exactly once (single
                    // attribution to the first net that lists it), matching the
                    // canonical-IR convention of the Magic path. The key is the
                    // unordered resolved-node pair, so it is independent of
                    // endpoint ordering and never drops a coupling that a writer
                    // lists only once (non-reciprocal SPEF).
                    if kind == .coupling {
                        let couplingKey = [resolvedA, resolvedB].sorted().joined(separator: "\u{1}")
                        if let previousValue = seenCouplingValues[couplingKey] {
                            let scale = Swift.max(abs(previousValue), abs(scaledValue))
                            guard abs(previousValue - scaledValue) <= scale * 1e-9 else {
                                throw PEXError.parseFailed(
                                    cornerID: cornerID,
                                    message: "SPEF coupling cap between \(resolvedA) and \(resolvedB) is listed with inconsistent values (\(previousValue) F vs \(scaledValue) F)"
                                )
                            }
                            continue
                        }
                        seenCouplingValues[couplingKey] = scaledValue
                    }

                    let remoteRef: NodeRef?
                    if let remoteNode {
                        let remoteNetName = externalNetName(
                            for: remoteNode,
                            explicitNodeOwners: explicitNodeOwners,
                            delimiter: delimiter
                        )
                        remoteRef = NodeRef(
                            netName: remoteNetName,
                            nodeName: NodeName(remoteNode)
                        )
                        externalNodesByNet[remoteNetName, default: []].insert(remoteNode)
                    } else {
                        remoteRef = NodeRef(netName: netName, nodeName: NodeName(resolvedB))
                    }

                    let element = ParasiticElement(
                        id: "\(netName.value)_C\(cap.id)",
                        kind: kind,
                        nodeA: NodeRef(netName: netName, nodeName: NodeName(localNode)),
                        nodeB: remoteRef,
                        value: scaledValue,
                        source: .extracted
                    )
                    allElements.append(element)

                    if kind == .coupling {
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

        let existingNetNames = Set(nets.map(\.name))
        for netName in externalNodesByNet.keys.sorted(by: { $0.value < $1.value }) where !existingNetNames.contains(netName) {
            let nodes = externalNodesByNet[netName, default: []].sorted().map { nodeName in
                ParasiticNode(
                    name: NodeName(nodeName),
                    kind: portNames.contains(nodeName) ? .pin : .internal,
                    instancePath: nil,
                    coordinate: nil
                )
            }
            nets.append(ParasiticNet(
                name: netName,
                nodes: nodes,
                totalGroundCapF: 0,
                totalCouplingCapF: 0,
                totalResistanceOhm: 0
            ))
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

    private func explicitNodeOwnerMap(from tree: SPEFParseTree) -> [String: NetName] {
        var owners: [String: NetName] = [:]
        for netBlock in tree.nets {
            let netName = NetName(resolveNameMap(netBlock.netName, nameMap: tree.nameMap))
            for node in localNodes(in: netBlock, nameMap: tree.nameMap) {
                owners[node] = netName
            }
        }
        return owners
    }

    private func localNodes(in netBlock: SPEFNetBlock, nameMap: [Int: String]) -> Set<String> {
        var nodes: Set<String> = []
        for connection in netBlock.connections {
            nodes.insert(resolveNameMap(connection.name, nameMap: nameMap))
        }
        for capacitor in netBlock.capacitors where capacitor.nodeB == nil {
            nodes.insert(resolveNameMap(capacitor.nodeA, nameMap: nameMap))
        }
        for resistor in netBlock.resistors {
            nodes.insert(resolveNameMap(resistor.nodeA, nameMap: nameMap))
            nodes.insert(resolveNameMap(resistor.nodeB, nameMap: nameMap))
        }
        return nodes
    }

    private func isLocalNode(
        _ nodeName: String,
        netName: NetName,
        localNodeSet: Set<String>,
        explicitNodeOwners: [String: NetName]
    ) -> Bool {
        localNodeSet.contains(nodeName) || explicitNodeOwners[nodeName] == netName
    }

    private func externalNetName(
        for nodeName: String,
        explicitNodeOwners: [String: NetName],
        delimiter: String
    ) -> NetName {
        if let netName = explicitNodeOwners[nodeName] {
            return netName
        }
        return NetName(ownerNetName(of: nodeName, delimiter: delimiter))
    }

    private func ownerNetName(of nodeName: String, delimiter: String) -> String {
        nodeName.components(separatedBy: delimiter).first ?? nodeName
    }
}
