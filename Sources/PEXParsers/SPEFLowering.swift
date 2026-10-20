import Foundation
import PEXCore

public struct SPEFLowering: Sendable {
    private let resources: PEXParserResourceScope?
    public init() { resources = nil }
    private init(resources: PEXParserResourceScope) { self.resources = resources }

    public func lower(_ tree: SPEFParseTree, cornerID: PEXCornerID,
        options: PEXRunOptions = .default, control: any PEXParserResourceControlling)
        throws -> (value: ParasiticIR, retention: PEXParserRetention) {
        let resources = try PEXParserResourceScope(control: control)
        let value = try Self(resources: resources).lower(tree, cornerID: cornerID, options: options)
        try resources.check(0)
        return (value, resources.retention)
    }

    public func lower(
        _ tree: SPEFParseTree,
        cornerID: PEXCornerID,
        options: PEXRunOptions = .default
    ) throws -> ParasiticIR {
        let generated = tree.header.program?.hasSuffix(" PEX_IDENTITY_V1") == true
        let annotated = try tree.nameMap.values.contains {
            try resources?.check()
            return $0.hasPrefix("PEX_IDENTITY_V1_")
        }
        if (tree.header.program?.contains(" PEX_CANONICAL_TERMINALS_V1") == true || annotated), !generated {
            throw try sourceFailure(diagnosticBytes: "SPEF identity annotation requires its generated profile marker".utf8.count) {
                PEXError.parseFailed(cornerID: cornerID, message: "SPEF identity annotation requires its generated profile marker")
            }
        }
        if generated {
            return try lowerGenerated(tree, cornerID: cornerID, options: options)
        }
        if let resources { try PEXParserLoweringStorage.admit(tree, scope: resources) }
        let (capScale, resScale, inductScale) = try unitScaleFactors(from: tree.header)
        let delimiter = tree.header.delimiter
        let explicitNodeOwners = try explicitNodeOwnerMap(from: tree)
        let instancePathByNode = try instancePathMap(from: tree, delimiter: delimiter)
        let portNames = Set(try tree.ports.map {
            try resources?.check()
            return resolveNameMap($0.name, nameMap: tree.nameMap)
        })
        let portCoordinates = Dictionary(uniqueKeysWithValues: try tree.ports.compactMap { port -> (String, Point2D)? in
            try resources?.check()
            guard let coordinate = port.coordinate else { return nil }
            return (resolveNameMap(port.name, nameMap: tree.nameMap), coordinate)
        })

        var nets: [ParasiticNet] = []
        var allElements: [ParasiticElement] = []
        var externalNodesByNet: [NetName: Set<String>] = [:]
        var couplingDedupe = CouplingDedupe(resources: resources)

        for netBlock in tree.nets {
            try resources?.check()
            let netName = NetName(resolveNameMap(netBlock.netName, nameMap: tree.nameMap))
            let localNodeSet = try localNodes(in: netBlock, nameMap: tree.nameMap)
            let connectionCoordinates = try connectionCoordinateMap(
                in: netBlock,
                nameMap: tree.nameMap,
                portCoordinates: portCoordinates
            )

            // Collect nodes from connections and element endpoints
            var nodeSet: Set<String> = []
            for conn in netBlock.connections {
                try resources?.check()
                nodeSet.insert(resolveNameMap(conn.name, nameMap: tree.nameMap))
            }
            for nodeCoordinate in netBlock.nodeCoordinates {
                try resources?.check()
                nodeSet.insert(resolveNameMap(nodeCoordinate.name, nameMap: tree.nameMap))
            }
            for cap in netBlock.capacitors {
                try resources?.check()
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
                try resources?.check()
                nodeSet.insert(resolveNameMap(res.nodeA, nameMap: tree.nameMap))
                nodeSet.insert(resolveNameMap(res.nodeB, nameMap: tree.nameMap))
            }
            for inductor in netBlock.inductors {
                try resources?.check()
                nodeSet.insert(resolveNameMap(inductor.nodeA, nameMap: tree.nameMap))
                nodeSet.insert(resolveNameMap(inductor.nodeB, nameMap: tree.nameMap))
            }

            // Build node list
            let nodes = try nodeSet.sorted {
                try resources?.check()
                return $0 < $1
            }.map { nodeName -> ParasiticNode in
                try resources?.check()
                let kind: NodeKind = try netBlock.connections.contains(where: {
                    try resources?.check()
                    return resolveNameMap($0.name, nameMap: tree.nameMap) == nodeName
                }) ? .pin : .internal
                return ParasiticNode(
                    name: NodeName(nodeName),
                    kind: kind,
                    instancePath: instancePathByNode[nodeName],
                    coordinate: connectionCoordinates[nodeName]
                )
            }

            // Convert capacitors
            var totalGroundCap = 0.0
            var totalCouplingCap = 0.0
            for cap in netBlock.capacitors {
                try resources?.check()
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
                        if try couplingDedupe.shouldSkipReciprocalDuplicate(
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
                try resources?.check()
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
                try resources?.check()
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

        let existingNetNames = Set(try nets.map {
            try resources?.check()
            return $0.name
        })
        for netName in try externalNodesByNet.keys.sorted(by: {
            try resources?.check()
            return $0.value < $1.value
        }) where !existingNetNames.contains(netName) {
            try resources?.check()
            let nodes = try externalNodesByNet[netName, default: []].sorted {
                try resources?.check()
                return $0 < $1
            }.map { nodeName in
                try resources?.check()
                return ParasiticNode(
                    name: NodeName(nodeName),
                    kind: portNames.contains(nodeName) ? .pin : .internal,
                    instancePath: instancePathByNode[nodeName],
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
                "topCell": tree.header.designName,
            ]
        )
    }

    private func lowerGenerated(_ tree: SPEFParseTree, cornerID: PEXCornerID,
                                options: PEXRunOptions) throws -> ParasiticIR {
        let prefix = "PEX_IDENTITY_V1_"
        if let resources {
            var annotationBytes = 0
            for value in tree.nameMap.values {
                try resources.check()
                annotationBytes = try PEXParserStorageSize.add(annotationBytes, value.utf8.count)
            }
            let decoded = annotationBytes / 2
            let base64 = try PEXParserStorageSize.multiply(
                PEXParserStorageSize.add(decoded, 2) / 3, 4)
            var bytes = try PEXParserStorageSize.array(String.self, count: tree.nameMap.count)
            bytes = try PEXParserStorageSize.add(bytes, PEXParserStorageSize.array(UInt8.self, count: annotationBytes))
            bytes = try PEXParserStorageSize.add(bytes, PEXParserStorageSize.multiply(PEXParserStorageSize.array(UInt8.self, count: decoded), 2))
            // Decoded Data, base64 output and the prefixed annotation String.
            bytes = try PEXParserStorageSize.add(bytes, decoded)
            bytes = try PEXParserStorageSize.add(bytes, base64)
            bytes = try PEXParserStorageSize.add(bytes, PEXParserStorageSize.add(base64, PEXSPICEIdentity.marker.utf8.count))
            bytes = try PEXParserStorageSize.add(bytes,
                MemoryLayout<Data>.stride + 2 * MemoryLayout<String>.stride)
            try resources.reserve(kind: .temporary, byteCount: UInt64(bytes))
        }
        let annotations = try tree.nameMap.values.filter {
            try resources?.check()
            return $0.hasPrefix(prefix)
        }
        guard annotations.count == 1 else {
            throw try sourceFailure(diagnosticBytes: "Generated SPEF requires one identity annotation".utf8.count) {
                PEXError.parseFailed(cornerID: cornerID, message: "Generated SPEF requires one identity annotation")
            }
        }
        let hex = Array(annotations[0].dropFirst(prefix.count).utf8)
        guard hex.count.isMultiple(of: 2) else {
            throw try sourceFailure(diagnosticBytes: "Malformed SPEF identity annotation".utf8.count) {
                PEXError.parseFailed(cornerID: cornerID, message: "Malformed SPEF identity annotation")
            }
        }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: hex.count, by: 2) {
            try resources?.check()
            guard let byte = UInt8(String(decoding: hex[index...index + 1], as: UTF8.self), radix: 16) else {
                throw try sourceFailure(diagnosticBytes: "Malformed SPEF identity annotation".utf8.count) {
                PEXError.parseFailed(cornerID: cornerID, message: "Malformed SPEF identity annotation")
            }
            }
            bytes.append(byte)
        }
        let annotation = PEXSPICEIdentity.marker + Data(bytes).base64EncodedString()
        let identity: PEXSPICEIdentity?
        if let resources {
            try resources.check(0)
            identity = try PEXSPICEIdentity.read(annotation, cornerID: cornerID,
                caseInsensitive: false, scope: resources)
        } else {
            identity = try PEXSPICEIdentity.read(annotation, cornerID: cornerID, caseInsensitive: false)
        }
        guard let identity else {
            throw try sourceFailure(diagnosticBytes: "Missing SPEF identity annotation".utf8.count) {
                PEXError.parseFailed(cornerID: cornerID, message: "Missing SPEF identity annotation")
            }
        }
        if let resources {
            var count = 0, identifierBytes = 0
            for block in tree.nets {
                try resources.check()
                let rows = try PEXParserStorageSize.add(block.capacitors.count,
                    PEXParserStorageSize.add(block.resistors.count, block.inductors.count))
                count = try PEXParserStorageSize.add(count, rows)
                let nameBytes = try PEXParserLoweringStorage.resolvedNameByteCount(block.netName, nameMap: tree.nameMap, scope: resources)
                identifierBytes = try PEXParserStorageSize.add(identifierBytes,
                    PEXParserStorageSize.multiply(rows, PEXParserStorageSize.add(nameBytes, 22)))
            }
            try resources.reserve(kind: .retained, byteCount: UInt64(identifierBytes))
            var capacity = try PEXParserStorageSize.add(identifierBytes,
                PEXParserStorageSize.array(PEXStandardIdentityLowering.Record.self, count: count))
            capacity = try PEXParserStorageSize.add(capacity, PEXParserStorageSize.array(String.self, count: tree.ports.count))
            // Canonical roots/top-port/connection sets, coordinates and path map.
            capacity = try PEXParserStorageSize.add(capacity,
                PEXParserStorageSize.multiply(PEXParserStorageSize.array(String.self, count: identity.nodes.count), 4))
            capacity = try PEXParserStorageSize.add(capacity,
                PEXParserStorageSize.dictionary(String.self, Point2D.self, count: identity.nodes.count))
            capacity = try PEXParserStorageSize.add(capacity,
                PEXParserStorageSize.dictionary(String.self, InstancePath.self, count: identity.nodes.count))
            // Old/new record and set/map buffers can coexist before replacement.
            try resources.reserve(kind: .temporary, byteCount: UInt64(
                try PEXParserStorageSize.multiply(capacity, 2)))
        }
        let canonical = tree.header.program?.contains(" PEX_CANONICAL_TERMINALS_V1") == true
        guard identity.canonicalTerminals == nil || identity.canonicalTerminals == true,
              canonical == (identity.canonicalTerminals == true) else {
            throw try sourceFailure(diagnosticBytes: "SPEF terminal profile marker disagrees with its identity annotation".utf8.count) {
                PEXError.parseFailed(cornerID: cornerID, message: "SPEF terminal profile marker disagrees with its identity annotation")
            }
        }
        if canonical {
            let roots = Set(try tree.nets.map {
                try resources?.check()
                return resolveNameMap($0.netName, nameMap: tree.nameMap)
            })
            guard identity.referenceToken == "0", identity.referenceName == "0",
                  try identity.nodes.allSatisfy({ token, node in
                      try resources?.check()
                      return !token.contains("\\") && token != "0"
                          && (!roots.contains(token) || (node.kind == .pin && token == node.ref.netName.value))
                          && (node.kind != .pin || token == node.ref.nodeName.value)
                  }) else {
                throw try sourceFailure(diagnosticBytes: "Canonical SPEF token disagrees with scoped identity".utf8.count) {
                PEXError.parseFailed(cornerID: cornerID, message: "Canonical SPEF token disagrees with scoped identity")
            }
            }
        }
        for (token, node) in identity.nodes {
            try resources?.check()
            if let path = node.instancePath {
                if let resources {
                    let sourceBytes = try PEXParserStorageSize.add(path.value.utf8.count, tree.header.delimiter.utf8.count)
                    let tokenBytes = try PEXParserStorageSize.add(PEXParserStorageSize.multiply(path.value.utf8.count, 2),
                        PEXParserStorageSize.add("PEX_INSTANCE_".utf8.count, tree.header.delimiter.utf8.count))
                    try resources.reserve(kind: .temporary, byteCount: UInt64(
                        try PEXParserStorageSize.add(2 * MemoryLayout<String>.stride,
                            PEXParserStorageSize.add(sourceBytes, PEXParserStorageSize.multiply(tokenBytes, 2)))))
                }
                let sourcePrefix = path.value + tree.header.delimiter
                let tokenPrefix: String
                if canonical {
                    tokenPrefix = sourcePrefix
                } else {
                    let encodedPath: String
                    if let resources { encodedPath = try PEXSPICEIdentity.hex(path.value, scope: resources) }
                    else { encodedPath = PEXSPICEIdentity.hex(path.value) }
                    tokenPrefix = "PEX_INSTANCE_" + encodedPath + tree.header.delimiter
                }
                guard node.kind == .pin, !path.value.isEmpty, !tree.header.delimiter.isEmpty,
                      node.ref.nodeName.value.hasPrefix(sourcePrefix), token.hasPrefix(tokenPrefix),
                      !node.ref.nodeName.value.dropFirst(sourcePrefix.count).isEmpty,
                      !node.ref.nodeName.value.dropFirst(sourcePrefix.count).contains(tree.header.delimiter) else {
                    throw try sourceFailure(diagnosticBytes: "SPEF instance pin disagrees with its declared path".utf8.count) {
                PEXError.parseFailed(cornerID: cornerID, message: "SPEF instance pin disagrees with its declared path")
            }
                }
            }
        }
        let topPorts = try tree.ports.map {
            try resources?.check()
            return resolveNameMap($0.name, nameMap: tree.nameMap)
        }
        let expectedTopPorts = Set(try identity.nodes.compactMap { token, node in
            try resources?.check()
            return node.kind == .pin && node.instancePath == nil ? token : nil
        })
        guard Set(topPorts).count == topPorts.count, Set(topPorts) == expectedTopPorts else {
            throw try sourceFailure(diagnosticBytes: "SPEF top-port inventory disagrees with scoped identity".utf8.count) {
                PEXError.parseFailed(cornerID: cornerID, message: "SPEF top-port inventory disagrees with scoped identity")
            }
        }
        let scales = try unitScaleFactors(from: tree.header)
        var connections = Set<String>()
        var records: [PEXStandardIdentityLowering.Record] = []
        var coordinates: [String: Point2D] = [:]
        for block in tree.nets {
            try resources?.check()
            let net = resolveNameMap(block.netName, nameMap: tree.nameMap)
            for connection in block.connections {
                try resources?.check()
                let token = resolveNameMap(connection.name, nameMap: tree.nameMap)
                guard let node = identity.nodes[token], node.ref.netName.value == net, node.kind == .pin,
                      connections.insert(token).inserted,
                      connection.type == (node.instancePath == nil ? .port : .instancePin) else {
                    throw try sourceFailure(diagnosticBytes: "SPEF connection disagrees with scoped identity".utf8.count) {
                PEXError.parseFailed(cornerID: cornerID, message: "SPEF connection disagrees with scoped identity")
            }
                }
            }
            for connection in block.connections {
                try resources?.check()
                if let coordinate = connection.coordinate {
                    coordinates[resolveNameMap(connection.name, nameMap: tree.nameMap)] = coordinate
                }
            }
            for entry in block.nodeCoordinates {
                try resources?.check()
                let token = resolveNameMap(entry.name, nameMap: tree.nameMap)
                guard identity.nodes[token]?.ref.netName.value == net else {
                    throw try sourceFailure(diagnosticBytes: "SPEF coordinate disagrees with scoped identity".utf8.count) {
                PEXError.parseFailed(cornerID: cornerID, message: "SPEF coordinate disagrees with scoped identity")
            }
                }
                coordinates[token] = entry.coordinate
            }
            func append(_ id: String, _ expected: ElementKind, _ a: String, _ b: String?, _ value: Double) throws {
                let a = resolveNameMap(a, nameMap: tree.nameMap)
                let b = b.map { resolveNameMap($0, nameMap: tree.nameMap) }
                guard identity.nodes[a]?.ref.netName.value == net,
                      let kind = identity.elementKinds[id],
                      (expected == .capacitor ? kind == .capacitor || kind == .coupling : kind == expected) else {
                    throw try sourceFailure(diagnosticBytes: "SPEF operator disagrees with scoped identity".utf8.count) {
                PEXError.parseFailed(cornerID: cornerID, message: "SPEF operator disagrees with scoped identity")
            }
                }
                if expected == .resistor || expected == .inductor {
                    guard let b, identity.nodes[b]?.ref.netName.value == net else {
                        throw try sourceFailure(diagnosticBytes: "SPEF cross-net resistor or inductor is unrepresentable".utf8.count) {
                PEXError.parseFailed(cornerID: cornerID, message: "SPEF cross-net resistor or inductor is unrepresentable")
            }
                    }
                }
                records.append(.init(id: id, kind: kind, nodeA: a, nodeB: b, value: value))
            }
            for cap in block.capacitors { try append(net + "_C" + String(cap.id), .capacitor, cap.nodeA, cap.nodeB, cap.value * scales.cap) }
            for res in block.resistors { try append(net + "_R" + String(res.id), .resistor, res.nodeA, res.nodeB, res.value * scales.res) }
            for ind in block.inductors { try append(net + "_L" + String(ind.id), .inductor, ind.nodeA, ind.nodeB, ind.value * scales.induct) }
        }
        guard connections == Set(try identity.nodes.compactMap({ token, node in
            try resources?.check()
            return node.kind == .pin ? token : nil
        })) else {
            throw try sourceFailure(diagnosticBytes: "SPEF pin connection inventory is incomplete".utf8.count) {
                PEXError.parseFailed(cornerID: cornerID, message: "SPEF pin connection inventory is incomplete")
            }
        }
        let context = PEXParseContext(cornerID: cornerID, runID: PEXRunID(), technology: nil, options: options)
        if let resources {
            return try PEXStandardIdentityLowering.lower(records, identity: identity, context: context,
                sourceFormat: "SPEF", coordinates: coordinates,
                verifiedInstancePaths: try identity.nodes.compactMapValues {
                    try resources.check()
                    return $0.instancePath
                }, scope: resources)
        }
        return try PEXStandardIdentityLowering.lower(records, identity: identity, context: context, sourceFormat: "SPEF", coordinates: coordinates,
            verifiedInstancePaths: identity.nodes.compactMapValues { $0.instancePath })
    }

    /// Returns scale factors to convert header units to canonical (Farad, Ohm, Henry).
    private func unitScaleFactors(from header: SPEFHeader) throws -> (cap: Double, res: Double, induct: Double) {
        let capBase: Double
        switch try uppercase(header.capUnit) {
        case "PF": capBase = 1e-12
        case "FF": capBase = 1e-15
        case "NF": capBase = 1e-9
        case "F": capBase = 1.0
        default: capBase = 1e-12
        }

        let resBase: Double
        switch try uppercase(header.resUnit) {
        case "OHM": resBase = 1.0
        case "KOHM": resBase = 1e3
        case "MOHM": resBase = 1e6
        default: resBase = 1.0
        }

        let inductBase: Double
        switch try uppercase(header.inductUnit ?? "HENRY") {
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

    private func sourceFailure(diagnosticBytes: Int, _ make: () -> PEXError) throws -> any Error {
        guard let resources else { return make() }
        return try resources.sourceFailure(diagnosticBytes: diagnosticBytes, make)
    }

    private func uppercase(_ text: String) throws -> String {
        guard let resources else { return text.uppercased() }
        return try PEXParserTextSizing.uppercased(text, kind: .temporary, scope: resources)
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

    private func explicitNodeOwnerMap(from tree: SPEFParseTree) throws -> [String: NetName] {
        var owners: [String: NetName] = [:]
        for netBlock in tree.nets {
            try resources?.check()
            let netName = NetName(resolveNameMap(netBlock.netName, nameMap: tree.nameMap))
            for node in try localNodes(in: netBlock, nameMap: tree.nameMap) {
                try resources?.check()
                owners[node] = netName
            }
        }
        return owners
    }

    private func instancePathMap(from tree: SPEFParseTree, delimiter: String) throws -> [String: InstancePath] {
        var paths: [String: InstancePath] = [:]
        for netBlock in tree.nets {
            try resources?.check()
            for connection in netBlock.connections where connection.type == .instancePin {
                try resources?.check()
                let nodeName = resolveNameMap(connection.name, nameMap: tree.nameMap)
                let path = nodeName.components(separatedBy: delimiter).first ?? nodeName
                guard !path.isEmpty, path != nodeName else { continue }
                paths[nodeName] = InstancePath(path)
            }
        }
        return paths
    }

    private func localNodes(in netBlock: SPEFNetBlock, nameMap: [Int: String]) throws -> Set<String> {
        var nodes: Set<String> = []
        for connection in netBlock.connections {
            try resources?.check()
            nodes.insert(resolveNameMap(connection.name, nameMap: nameMap))
        }
        for nodeCoordinate in netBlock.nodeCoordinates {
            try resources?.check()
            nodes.insert(resolveNameMap(nodeCoordinate.name, nameMap: nameMap))
        }
        for capacitor in netBlock.capacitors where capacitor.nodeB == nil {
            try resources?.check()
            nodes.insert(resolveNameMap(capacitor.nodeA, nameMap: nameMap))
        }
        for resistor in netBlock.resistors {
            try resources?.check()
            nodes.insert(resolveNameMap(resistor.nodeA, nameMap: nameMap))
            nodes.insert(resolveNameMap(resistor.nodeB, nameMap: nameMap))
        }
        for inductor in netBlock.inductors {
            try resources?.check()
            nodes.insert(resolveNameMap(inductor.nodeA, nameMap: nameMap))
            nodes.insert(resolveNameMap(inductor.nodeB, nameMap: nameMap))
        }
        return nodes
    }

    private func connectionCoordinateMap(
        in netBlock: SPEFNetBlock,
        nameMap: [Int: String],
        portCoordinates: [String: Point2D]
    ) throws -> [String: Point2D] {
        var coordinates = portCoordinates
        for connection in netBlock.connections {
            try resources?.check()
            guard let coordinate = connection.coordinate else { continue }
            coordinates[resolveNameMap(connection.name, nameMap: nameMap)] = coordinate
        }
        for nodeCoordinate in netBlock.nodeCoordinates {
            try resources?.check()
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
    let resources: PEXParserResourceScope?
    private var pendingByEndpointPair: [CouplingEndpointPair: [PendingCoupling]] = [:]

    mutating func shouldSkipReciprocalDuplicate(
        endpointPair: CouplingEndpointPair,
        netName: NetName,
        value: Double
    ) throws -> Bool {
        try resources?.check()
        var pending = pendingByEndpointPair[endpointPair, default: []]
        if let matchIndex = try pending.firstIndex(where: { candidate in
            try resources?.check()
            return candidate.netName != netName && Self.valuesMatch(candidate.value, value)
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
            try resources?.check()
            let netNames = Set(try pending.map {
                try resources?.check()
                return $0.netName
            })
            guard netNames.count > 1 else { continue }

            var diagnosticBytes = 0
            if let resources {
                var rowBytes = 0
                for value in pending {
                    try resources.check()
                    rowBytes = try PEXParserStorageSize.add(rowBytes,
                        PEXParserStorageSize.add(value.netName.value.utf8.count, 1 + 24 + 2))
                }
                let separators = try PEXParserStorageSize.multiply(Swift.max(pending.count - 1, 0), 2)
                let joinedBytes = try PEXParserStorageSize.add(rowBytes, separators)
                let arrays = try PEXParserStorageSize.multiply(
                    PEXParserStorageSize.array(String.self, count: pending.count), 2)
                let scratch = try PEXParserStorageSize.add(arrays,
                    PEXParserStorageSize.add(rowBytes, joinedBytes))
                try resources.reserve(kind: .temporary, byteCount: UInt64(scratch))
                diagnosticBytes = try PEXParserStorageSize.add(
                    "SPEF coupling cap between  and  is listed with inconsistent values ()".utf8.count,
                    PEXParserStorageSize.add(endpointPair.nodeA.utf8.count,
                        PEXParserStorageSize.add(endpointPair.nodeB.utf8.count, joinedBytes)))
            }
            let values = try pending
                .map {
                    try resources?.check()
                    return "\($0.netName.value)=\($0.value) F"
                }
                .sorted {
                    try resources?.check()
                    return $0 < $1
                }
                .joined(separator: ", ")
            let make = {
                PEXError.parseFailed(cornerID: cornerID,
                    message: "SPEF coupling cap between \(endpointPair.nodeA) and \(endpointPair.nodeB) is listed with inconsistent values (\(values))")
            }
            if let resources { throw try resources.sourceFailure(diagnosticBytes: diagnosticBytes, make) }
            throw make()
        }
    }

    private static func valuesMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        let scale = Swift.max(abs(lhs), abs(rhs))
        return abs(lhs - rhs) <= scale * 1e-9
    }
}

struct CouplingEndpointPair: Sendable, Hashable {
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

struct PendingCoupling: Sendable {
    let netName: NetName
    let value: Double
}
