import Foundation
import PEXCore

public struct SPEFLowering: Sendable {
    public init() {}

    public func lower(
        _ tree: SPEFParseTree,
        cornerID: PEXCornerID,
        options: PEXRunOptions = .default
    ) throws -> ParasiticIR {
        let (capScale, resScale, inductScale) = unitScaleFactors(from: tree.header)
        let delimiter = tree.header.delimiter
        let explicitNodeOwners = explicitNodeOwnerMap(from: tree)
        let portNames = Set(tree.ports.map { resolveNameMap($0.name, nameMap: tree.nameMap) })
        let portCoordinates = Dictionary(uniqueKeysWithValues: tree.ports.compactMap { port -> (String, Point2D)? in
            guard let coordinate = port.coordinate else { return nil }
            return (resolveNameMap(port.name, nameMap: tree.nameMap), coordinate)
        })

        var nets: [ParasiticNet] = []
        var allElements: [ParasiticElement] = []
        var externalNodesByNet: [NetName: Set<String>] = [:]
        var couplingDedupe = CouplingDedupe()

        for netBlock in tree.nets {
            let netName = NetName(resolveNameMap(netBlock.netName, nameMap: tree.nameMap))
            let localNodeSet = localNodes(in: netBlock, nameMap: tree.nameMap)
            let connectionCoordinates = connectionCoordinateMap(
                in: netBlock,
                nameMap: tree.nameMap,
                portCoordinates: portCoordinates
            )

            // Collect nodes from connections and element endpoints
            var nodeSet: Set<String> = []
            for conn in netBlock.connections {
                nodeSet.insert(resolveNameMap(conn.name, nameMap: tree.nameMap))
            }
            for nodeCoordinate in netBlock.nodeCoordinates {
                nodeSet.insert(resolveNameMap(nodeCoordinate.name, nameMap: tree.nameMap))
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
            for inductor in netBlock.inductors {
                nodeSet.insert(resolveNameMap(inductor.nodeA, nameMap: tree.nameMap))
                nodeSet.insert(resolveNameMap(inductor.nodeB, nameMap: tree.nameMap))
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
                    coordinate: connectionCoordinates[nodeName]
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

                    if kind == .coupling {
                        let endpointPair = CouplingEndpointPair(resolvedA, resolvedB)
                        if couplingDedupe.shouldSkipReciprocalDuplicate(
                            endpointPair: endpointPair,
                            netName: netName,
                            value: scaledValue
                        ) {
                            continue
                        }
                    }

                    guard options.extractMode != .rOnly else { continue }
                    if kind == .coupling && !options.includeCouplingCaps {
                        continue
                    }
                    if let minCapacitanceF = options.minCapacitanceF, scaledValue < minCapacitanceF {
                        continue
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
                    } else {
                        totalGroundCap += scaledValue
                    }
                } else {
                    guard options.extractMode != .rOnly else { continue }
                    if let minCapacitanceF = options.minCapacitanceF, scaledValue < minCapacitanceF {
                        continue
                    }
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
                guard options.extractMode != .cOnly else { continue }
                let resolvedA = resolveNameMap(res.nodeA, nameMap: tree.nameMap)
                let resolvedB = resolveNameMap(res.nodeB, nameMap: tree.nameMap)
                let scaledValue = res.value * resScale
                if let minResistanceOhm = options.minResistanceOhm, scaledValue < minResistanceOhm {
                    continue
                }

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

            // Convert inductors.
            for inductor in netBlock.inductors {
                guard options.extractMode == .rc else { continue }
                let resolvedA = resolveNameMap(inductor.nodeA, nameMap: tree.nameMap)
                let resolvedB = resolveNameMap(inductor.nodeB, nameMap: tree.nameMap)
                let scaledValue = inductor.value * inductScale

                let element = ParasiticElement(
                    id: "\(netName.value)_L\(inductor.id)",
                    kind: .inductor,
                    nodeA: NodeRef(netName: netName, nodeName: NodeName(resolvedA)),
                    nodeB: NodeRef(netName: netName, nodeName: NodeName(resolvedB)),
                    value: scaledValue,
                    source: .extracted
                )
                allElements.append(element)
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

        try couplingDedupe.validateNoMismatchedReciprocals(cornerID: cornerID)

        let existingNetNames = Set(nets.map(\.name))
        for netName in externalNodesByNet.keys.sorted(by: { $0.value < $1.value }) where !existingNetNames.contains(netName) {
            let nodes = externalNodesByNet[netName, default: []].sorted().map { nodeName in
                ParasiticNode(
                    name: NodeName(nodeName),
                    kind: portNames.contains(nodeName) ? .pin : .internal,
                    instancePath: nil,
                    coordinate: portCoordinates[nodeName]
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

    /// Returns scale factors to convert header units to canonical (Farad, Ohm, Henry).
    private func unitScaleFactors(from header: SPEFHeader) -> (cap: Double, res: Double, induct: Double) {
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

        let inductBase: Double
        switch (header.inductUnit ?? "HENRY").uppercased() {
        case "H", "HENRY": inductBase = 1.0
        case "MH": inductBase = 1e-3
        case "UH": inductBase = 1e-6
        case "NH": inductBase = 1e-9
        case "PH": inductBase = 1e-12
        default: inductBase = 1.0
        }

        return (
            capBase * header.capScaleFactor,
            resBase * header.resScaleFactor,
            inductBase * (header.inductScaleFactor ?? 1.0)
        )
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
        for nodeCoordinate in netBlock.nodeCoordinates {
            nodes.insert(resolveNameMap(nodeCoordinate.name, nameMap: nameMap))
        }
        for capacitor in netBlock.capacitors where capacitor.nodeB == nil {
            nodes.insert(resolveNameMap(capacitor.nodeA, nameMap: nameMap))
        }
        for resistor in netBlock.resistors {
            nodes.insert(resolveNameMap(resistor.nodeA, nameMap: nameMap))
            nodes.insert(resolveNameMap(resistor.nodeB, nameMap: nameMap))
        }
        for inductor in netBlock.inductors {
            nodes.insert(resolveNameMap(inductor.nodeA, nameMap: nameMap))
            nodes.insert(resolveNameMap(inductor.nodeB, nameMap: nameMap))
        }
        return nodes
    }

    private func connectionCoordinateMap(
        in netBlock: SPEFNetBlock,
        nameMap: [Int: String],
        portCoordinates: [String: Point2D]
    ) -> [String: Point2D] {
        var coordinates = portCoordinates
        for connection in netBlock.connections {
            guard let coordinate = connection.coordinate else { continue }
            coordinates[resolveNameMap(connection.name, nameMap: nameMap)] = coordinate
        }
        for nodeCoordinate in netBlock.nodeCoordinates {
            coordinates[resolveNameMap(nodeCoordinate.name, nameMap: nameMap)] = nodeCoordinate.coordinate
        }
        return coordinates
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

private struct CouplingDedupe: Sendable {
    private var pendingByEndpointPair: [CouplingEndpointPair: [PendingCoupling]] = [:]

    mutating func shouldSkipReciprocalDuplicate(
        endpointPair: CouplingEndpointPair,
        netName: NetName,
        value: Double
    ) -> Bool {
        var pending = pendingByEndpointPair[endpointPair, default: []]
        if let matchIndex = pending.firstIndex(where: { candidate in
            candidate.netName != netName && Self.valuesMatch(candidate.value, value)
        }) {
            pending.remove(at: matchIndex)
            pendingByEndpointPair[endpointPair] = pending.isEmpty ? nil : pending
            return true
        }

        pending.append(PendingCoupling(netName: netName, value: value))
        pendingByEndpointPair[endpointPair] = pending
        return false
    }

    func validateNoMismatchedReciprocals(cornerID: PEXCornerID) throws {
        for (endpointPair, pending) in pendingByEndpointPair {
            let netNames = Set(pending.map(\.netName))
            guard netNames.count > 1 else { continue }

            let values = pending
                .map { "\($0.netName.value)=\($0.value) F" }
                .sorted()
                .joined(separator: ", ")
            throw PEXError.parseFailed(
                cornerID: cornerID,
                message: "SPEF coupling cap between \(endpointPair.nodeA) and \(endpointPair.nodeB) is listed with inconsistent values (\(values))"
            )
        }
    }

    private static func valuesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        let scale = Swift.max(abs(lhs), abs(rhs))
        return abs(lhs - rhs) <= scale * 1e-9
    }
}

private struct CouplingEndpointPair: Sendable, Hashable {
    let nodeA: String
    let nodeB: String

    init(_ first: String, _ second: String) {
        if first <= second {
            nodeA = first
            nodeB = second
        } else {
            nodeA = second
            nodeB = first
        }
    }
}

private struct PendingCoupling: Sendable {
    let netName: NetName
    let value: Double
}
