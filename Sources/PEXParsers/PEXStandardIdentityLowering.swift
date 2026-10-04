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
                      context: PEXParseContext, sourceFormat: String, coordinates: [String: Point2D] = [:]) throws -> ParasiticIR {
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
                                         instancePath: nil, coordinate: coordinates[token])
                }.sorted { $0.name.value < $1.name.value },
                totalGroundCapF: ground, totalCouplingCapF: coupling, totalResistanceOhm: resistance)
        }
        return ParasiticIR(version: ParasiticIR.currentVersion, cornerID: context.cornerID,
                           units: .canonical, nets: nets, elements: elements,
                           metadata: ["sourceFormat": sourceFormat, "referenceNodeName": identity.referenceName])
    }
}
