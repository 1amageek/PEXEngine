import Foundation
import PEXCore

/// Reads actual standard element records through an admitted identity map.
struct PEXStandardIdentityLowering {
    struct Record {
        let id: String
        let kind: ElementKind
        let nodeA: String
        let nodeB: String?
        let value: Double
    }

    static func lower(_ records: [Record], identity: PEXSPICEIdentity,
                      context: PEXParseContext, sourceFormat: String, coordinates: [String: Point2D] = [:],
                      verifiedInstancePaths: [String: InstancePath] = [:]) throws -> ParasiticIR {
        func failure(_ message: String) -> PEXError {
            .parseFailed(cornerID: context.cornerID, message: message)
        }
        guard Set(records.map(\.id)).count == records.count,
              Set(records.map(\.id)) == Set(identity.elementKinds.keys) else {
            throw failure("Generated parasitic element inventory disagrees with identity annotation")
        }
        var elements: [ParasiticElement] = []
        for record in records {
            guard record.value.isFinite, record.value >= 0,
                  identity.elementKinds[record.id] == record.kind,
                  let a = identity.nodes[record.nodeA]?.ref else {
                throw failure("Invalid generated parasitic element \(record.id)")
            }
            let b: NodeRef?
            if let token = record.nodeB {
                guard let node = identity.nodes[token] else {
                    throw failure("Unknown generated parasitic endpoint \(token)")
                }
                b = node.ref
            } else {
                guard record.kind == .capacitor else {
                    throw failure("Generated parasitic element \(record.id) requires two endpoints")
                }
                b = nil
            }
            let options = context.options
            switch record.kind {
            case .resistor:
                if options.extractMode == .cOnly { continue }
                if let minimum = options.minResistanceOhm, record.value < minimum { continue }
            case .inductor:
                if options.extractMode != .rc { continue }
            case .capacitor, .coupling:
                if options.extractMode == .rOnly { continue }
                if record.kind == .coupling && !options.includeCouplingCaps { continue }
                if let minimum = options.minCapacitanceF, record.value < minimum { continue }
            }
            elements.append(ParasiticElement(id: record.id, kind: record.kind, nodeA: a,
                                            nodeB: b, value: record.value, source: .extracted))
        }
        let groups = Dictionary(grouping: identity.nodes.values, by: { $0.ref.netName })
        let nets = try groups.keys.sorted(by: { $0.value < $1.value }).map { name in
            let local = elements.filter { $0.nodeA.netName == name }
            let ground = local.filter { $0.kind == .capacitor }.reduce(0) { $0 + $1.value }
            let coupling = local.filter { $0.kind == .coupling }.reduce(0) { $0 + $1.value }
            let resistance = local.filter { $0.kind == .resistor }.reduce(0) { $0 + $1.value }
            guard ground.isFinite, coupling.isFinite, resistance.isFinite else {
                throw failure("Nonfinite generated parasitic inventory total")
            }
            return ParasiticNet(name: name,
                nodes: identity.nodes.keys.sorted().compactMap { token in
                    guard let node = identity.nodes[token], node.ref.netName == name else { return nil }
                    return ParasiticNode(name: node.ref.nodeName, kind: node.kind,
                                         instancePath: verifiedInstancePaths[token], coordinate: coordinates[token])
                }.sorted { $0.name.value < $1.name.value },
                totalGroundCapF: ground, totalCouplingCapF: coupling, totalResistanceOhm: resistance)
        }
        return ParasiticIR(version: ParasiticIR.currentVersion, cornerID: context.cornerID,
                           units: .canonical, nets: nets, elements: elements,
                           metadata: ["sourceFormat": sourceFormat, "referenceNodeName": identity.referenceName])
    }

    static func lower(_ records: [Record], identity: PEXSPICEIdentity,
                      context: PEXParseContext, sourceFormat: String,
                      coordinates: [String: Point2D] = [:],
                      verifiedInstancePaths: [String: InstancePath] = [:],
                      scope: PEXParserResourceScope) throws -> ParasiticIR {
        func failure(_ bytes: Int, _ message: () -> String) throws -> PEXParserSourceFailure {
            try scope.sourceFailure(diagnosticBytes:
                PEXParserStorageSize.add(MemoryLayout<String>.stride, bytes)) {
                    PEXError.parseFailed(cornerID: context.cornerID, message: message())
                }
        }
        // The private sets/ordered keys are admitted once at their actual upper
        // cardinalities. No append is charged as an entire prior array copy.
        let recordSet = try PEXParserStorageSize.add(MemoryLayout<Set<String>>.stride,
            PEXParserStorageSize.multiply(records.count, MemoryLayout<String>.stride))
        let nodeSet = try PEXParserStorageSize.add(MemoryLayout<Set<NetName>>.stride,
            PEXParserStorageSize.multiply(identity.nodes.count, MemoryLayout<NetName>.stride))
        let keys = try PEXParserStorageSize.add(
            PEXParserStorageSize.array(NetName.self, count: identity.nodes.count),
            PEXParserStorageSize.array(String.self, count: identity.nodes.count))
        let scratch = try PEXParserStorageSize.add(recordSet,
            PEXParserStorageSize.add(nodeSet, keys))
        return try scope.withTemporaryStorage(byteCount: UInt64(scratch)) {
            var ids: Set<String> = []
            ids.reserveCapacity(records.count)
            var inventoryMatches = records.count == identity.elementKinds.count
            for record in records {
                try scope.check()
                inventoryMatches = ids.insert(record.id).inserted && inventoryMatches
                inventoryMatches = identity.elementKinds[record.id] != nil && inventoryMatches
            }
            guard inventoryMatches else {
                throw try failure("Generated parasitic element inventory disagrees with identity annotation".utf8.count) { "Generated parasitic element inventory disagrees with identity annotation" }
            }
            try scope.reserve(kind: .retained, byteCount: UInt64(
                try PEXParserStorageSize.array(ParasiticElement.self, count: records.count)))
            var elements: [ParasiticElement] = []
            elements.reserveCapacity(records.count)
            for record in records {
                try scope.check()
                guard record.value.isFinite, record.value >= 0,
                      identity.elementKinds[record.id] == record.kind,
                      let a = identity.nodes[record.nodeA]?.ref else {
                    throw try failure(PEXParserStorageSize.add(
                        "Invalid generated parasitic element ".utf8.count, record.id.utf8.count)) {
                            "Invalid generated parasitic element \(record.id)"
                        }
                }
                let b: NodeRef?
                if let token = record.nodeB {
                    guard let node = identity.nodes[token] else {
                        throw try failure(PEXParserStorageSize.add(
                            "Unknown generated parasitic endpoint ".utf8.count, token.utf8.count)) {
                                "Unknown generated parasitic endpoint \(token)"
                            }
                    }
                    b = node.ref
                } else {
                    guard record.kind == .capacitor else {
                        throw try failure(PEXParserStorageSize.add(
                            "Generated parasitic element  requires two endpoints".utf8.count, record.id.utf8.count)) {
                                "Generated parasitic element \(record.id) requires two endpoints"
                            }
                    }
                    b = nil
                }
                let options = context.options
                switch record.kind {
                case .resistor:
                    if options.extractMode == .cOnly { continue }
                    if let minimum = options.minResistanceOhm, record.value < minimum { continue }
                case .inductor:
                    if options.extractMode != .rc { continue }
                case .capacitor, .coupling:
                    if options.extractMode == .rOnly { continue }
                    if record.kind == .coupling && !options.includeCouplingCaps { continue }
                    if let minimum = options.minCapacitanceF, record.value < minimum { continue }
                }
                elements.append(.init(id: record.id, kind: record.kind, nodeA: a,
                    nodeB: b, value: record.value, source: .extracted))
            }
            var nameSet: Set<NetName> = []
            nameSet.reserveCapacity(identity.nodes.count)
            for node in identity.nodes.values { try scope.check(); nameSet.insert(node.ref.netName) }
            // Sorting is an atomic standard-library call, bracketed by checks.
            try scope.check(UInt64(nameSet.count))
            let names = try nameSet.sorted { left, right in
                try scope.check(); return left.value < right.value
            }
            let tokens = try identity.nodes.keys.sorted { left, right in
                try scope.check(); return left < right
            }
            try scope.check(0)
            try scope.reserve(kind: .retained, byteCount: UInt64(
                try PEXParserStorageSize.array(ParasiticNet.self, count: names.count)))
            var nets: [ParasiticNet] = []
            nets.reserveCapacity(names.count)
            for name in names {
                try scope.check()
                var ground = 0.0, coupling = 0.0, resistance = 0.0
                for element in elements {
                    try scope.check()
                    guard element.nodeA.netName == name else { continue }
                    switch element.kind {
                    case .capacitor: ground += element.value
                    case .coupling: coupling += element.value
                    case .resistor: resistance += element.value
                    case .inductor: break
                    }
                }
                guard ground.isFinite, coupling.isFinite, resistance.isFinite else {
                    throw try failure("Nonfinite generated parasitic inventory total".utf8.count) { "Nonfinite generated parasitic inventory total" }
                }
                var count = 0
                for token in tokens {
                    try scope.check()
                    if identity.nodes[token]?.ref.netName == name { count += 1 }
                }
                try scope.reserve(kind: .retained, byteCount: UInt64(
                    try PEXParserStorageSize.array(ParasiticNode.self, count: count)))
                var nodes: [ParasiticNode] = []
                nodes.reserveCapacity(count)
                for token in tokens {
                    try scope.check()
                    guard let node = identity.nodes[token], node.ref.netName == name else { continue }
                    nodes.append(.init(name: node.ref.nodeName, kind: node.kind,
                        instancePath: verifiedInstancePaths[token], coordinate: coordinates[token]))
                }
                try nodes.sort { left, right in
                    try scope.check(); return left.name.value < right.name.value
                }
                try scope.check(0)
                nets.append(.init(name: name, nodes: nodes, totalGroundCapF: ground,
                    totalCouplingCapF: coupling, totalResistanceOhm: resistance))
            }
            try scope.reserve(kind: .retained, byteCount: UInt64(
                try PEXParserStorageSize.dictionary(String.self, String.self, count: 2)))
            return ParasiticIR(version: ParasiticIR.currentVersion, cornerID: context.cornerID,
                units: .canonical, nets: nets, elements: elements,
                metadata: ["sourceFormat": sourceFormat, "referenceNodeName": identity.referenceName])
        }
    }

}
