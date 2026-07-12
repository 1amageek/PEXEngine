import Foundation
import PEXCore

/// Writes a deterministic, standalone SPICE subcircuit containing every
/// positive parasitic element in canonical ParasiticIR.
///
/// The writer deliberately does not rewrite the source netlist.  It preserves
/// the extracted topology in a reusable fragment and emits a node map when a
/// net-scoped internal node must be made globally unique for SPICE.
public struct PEXSPICEWriter: Sendable {
    private let options: PEXSPICEWriterOptions

    public init(options: PEXSPICEWriterOptions = PEXSPICEWriterOptions()) {
        self.options = options
    }

    public func write(_ ir: ParasiticIR) throws -> String {
        let nodeMap = try makeNodeMap(for: ir)
        let elementIDs = try makeElementIDs(for: ir)
        let subcircuit = try makeSubcircuitName(for: ir)
        let ports = ir.nets
            .flatMap { net in
                net.nodes.filter { $0.kind == .pin }.map { NodeRef(netName: net.name, nodeName: $0.name) }
            }
            .compactMap { nodeMap[$0] }
            .filter { $0 != "0" }
            .deduplicated()

        var lines: [String] = []
        lines.append("* PEX backannotation generated from ParasiticIR \(ir.version)")
        lines.append("* Corner: \(ir.cornerID.value)")
        lines.append("* Units: resistance=ohm capacitance=F inductance=H")
        if options.includeNodeMapComments {
            for entry in nodeMap.entries {
                guard entry.key.nodeName.value != entry.value else { continue }
                lines.append("* PEX_NODE_MAP \(commentToken(entry.key.netName.value)) \(commentToken(entry.key.nodeName.value)) -> \(entry.value)")
            }
        }
        let portText = ports.joined(separator: " ")
        lines.append(".subckt \(subcircuit)\(portText.isEmpty ? "" : " \(portText)")")

        for element in ir.elements.sorted(by: { $0.id < $1.id }) {
            guard element.value.isFinite else { throw PEXSPICEWriterError.nonFiniteValue(element.id) }
            guard element.value >= 0 else { throw PEXSPICEWriterError.negativeValue(element.id) }
            guard let elementID = elementIDs[element.id] else {
                throw PEXSPICEWriterError.invalidElementIdentifier(element.id)
            }
            let nodeA = try nodeToken(for: element.nodeA, nodeMap: nodeMap)
            let value: Double
            switch element.kind {
            case .resistor:
                guard let nodeB = element.nodeB else { throw PEXSPICEWriterError.missingEndpoint(element.id) }
                value = element.value * resistanceScale(ir.units.resistance)
                lines.append("RPEX_\(elementID) \(nodeA) \(try nodeToken(for: nodeB, nodeMap: nodeMap)) \(format(value))")
            case .capacitor:
                value = element.value * capacitanceScale(ir.units.capacitance)
                let nodeB: String
                if let ref = element.nodeB {
                    nodeB = try nodeToken(for: ref, nodeMap: nodeMap)
                } else {
                    nodeB = "0"
                }
                lines.append("CPEX_\(elementID) \(nodeA) \(nodeB) \(format(value))")
            case .coupling:
                guard let nodeB = element.nodeB else { throw PEXSPICEWriterError.missingEndpoint(element.id) }
                value = element.value * capacitanceScale(ir.units.capacitance)
                lines.append("CPEX_\(elementID) \(nodeA) \(try nodeToken(for: nodeB, nodeMap: nodeMap)) \(format(value))")
            case .inductor:
                guard let nodeB = element.nodeB else { throw PEXSPICEWriterError.missingEndpoint(element.id) }
                value = element.value
                lines.append("LPEX_\(elementID) \(nodeA) \(try nodeToken(for: nodeB, nodeMap: nodeMap)) \(format(value))")
            }
        }

        lines.append(".ends \(subcircuit)")
        return lines.joined(separator: "\n") + "\n"
    }

    public func write(_ ir: ParasiticIR, to url: URL) throws {
        do {
            try Data(write(ir).utf8).write(to: url, options: .atomic)
        } catch let error as PEXSPICEWriterError {
            throw error
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to write SPICE backannotation to \(url.path(percentEncoded: false))",
                underlying: error
            )
        }
    }

    private func makeSubcircuitName(for ir: ParasiticIR) throws -> String {
        let raw = options.subcircuitName ?? "PEX_\(ir.metadata["topCell"] ?? "TOP")_\(ir.cornerID.value)"
        let value = sanitizeIdentifier(raw)
        guard !value.isEmpty else { throw PEXSPICEWriterError.invalidElementIdentifier(raw) }
        return value
    }

    private func makeElementIDs(for ir: ParasiticIR) throws -> [String: String] {
        var used: Set<String> = []
        var result: [String: String] = [:]
        for element in ir.elements.sorted(by: { $0.id < $1.id }) {
            let base = sanitizeIdentifier(element.id)
            guard !base.isEmpty else { throw PEXSPICEWriterError.invalidElementIdentifier(element.id) }
            var candidate = base
            var suffix = 2
            while !used.insert(candidate).inserted {
                candidate = "\(base)_\(suffix)"
                suffix += 1
            }
            result[element.id] = candidate
        }
        return result
    }

    private func makeNodeMap(for ir: ParasiticIR) throws -> NodeMap {
        let refs = ir.nets
            .flatMap { net in net.nodes.map { NodeRef(netName: net.name, nodeName: $0.name) } }
            .sorted { lhs, rhs in
                if lhs.netName.value != rhs.netName.value { return lhs.netName.value < rhs.netName.value }
                return lhs.nodeName.value < rhs.nodeName.value
            }
        var map: [NodeRef: String] = [:]
        var tokenOwners: [String: NodeRef] = [:]
        let pinRefs = Set(ir.nets.flatMap { net in
            net.nodes.filter { $0.kind == .pin || $0.kind == .ground }.map { NodeRef(netName: net.name, nodeName: $0.name) }
        })
        let nameCounts = Dictionary(grouping: refs, by: { $0.nodeName.value }).mapValues(\.count)

        for ref in refs {
            let raw = ref.nodeName.value
            let base: String
            if raw.isEmpty {
                throw PEXSPICEWriterError.invalidNodeName(raw)
            } else if raw == "0" || raw.caseInsensitiveCompare("gnd") == .orderedSame {
                base = "0"
            } else if pinRefs.contains(ref) && (nameCounts[raw] ?? 0) == 1 {
                base = raw
            } else if (nameCounts[raw] ?? 0) == 1 {
                base = raw
            } else {
                base = "PEX_\(sanitizeIdentifier(ref.netName.value))_\(sanitizeIdentifier(raw))"
            }
            try validateNodeToken(base, original: raw)
            if let owner = tokenOwners[base], owner != ref {
                let ownerIsGround = isGround(owner, in: ir)
                let refIsGround = isGround(ref, in: ir)
                guard base == "0", ownerIsGround, refIsGround else {
                    throw PEXSPICEWriterError.nodeIdentityCollision("\(owner.netName.value):\(owner.nodeName.value) and \(ref.netName.value):\(ref.nodeName.value) -> \(base)")
                }
            }
            tokenOwners[base] = ref
            map[ref] = base
        }
        return NodeMap(values: map)
    }

    private func nodeToken(for ref: NodeRef, nodeMap: NodeMap) throws -> String {
        if ref.nodeName.value == "0" || ref.nodeName.value.caseInsensitiveCompare("gnd") == .orderedSame {
            return "0"
        }
        guard let token = nodeMap[ref] else {
            throw PEXSPICEWriterError.invalidNodeName(ref.nodeName.value)
        }
        return token
    }

    private func validateNodeToken(_ value: String, original: String) throws {
        guard !value.isEmpty,
              value.allSatisfy({ !$0.isWhitespace && !$0.isNewline }),
              !value.contains(where: { $0 == ";" || $0 == "\"" || $0 == "(" || $0 == ")" })
        else {
            throw PEXSPICEWriterError.invalidNodeName(original)
        }
    }

    private func isGround(_ ref: NodeRef, in ir: ParasiticIR) -> Bool {
        if ref.nodeName.value == "0" || ref.nodeName.value.caseInsensitiveCompare("gnd") == .orderedSame {
            return true
        }
        return ir.nets
            .first(where: { $0.name == ref.netName })?
            .nodes
            .first(where: { $0.name == ref.nodeName })?
            .kind == .ground
    }

    private func sanitizeIdentifier(_ value: String) -> String {
        let mapped = value.map { character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private func commentToken(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: "_").replacingOccurrences(of: "\r", with: "_")
    }

    private func resistanceScale(_ unit: ParasiticUnits.ResistanceUnit) -> Double {
        switch unit {
        case .ohm: return 1
        case .kiloOhm: return 1_000
        }
    }

    private func capacitanceScale(_ unit: ParasiticUnits.CapacitanceUnit) -> Double {
        switch unit {
        case .farad: return 1
        case .picoFarad: return 1e-12
        case .femtoFarad: return 1e-15
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.12e", value)
    }
}

private struct NodeMap: Sendable {
    let values: [NodeRef: String]

    subscript(_ ref: NodeRef) -> String? { values[ref] }

    var entries: [(key: NodeRef, value: String)] {
        values.sorted { lhs, rhs in
            if lhs.key.netName.value != rhs.key.netName.value {
                return lhs.key.netName.value < rhs.key.netName.value
            }
            return lhs.key.nodeName.value < rhs.key.nodeName.value
        }
    }
}

private extension Array where Element: Hashable {
    func deduplicated() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
