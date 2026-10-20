import Foundation
import PEXCore

/// Writes a deterministic, standalone SPICE subcircuit containing every
/// nonnegative parasitic element in canonical ParasiticIR.
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
        let referenceName = ir.metadata["referenceNodeName"] ?? "0"
        try validateNodeToken(referenceName, original: referenceName)
        let referenceToken = referenceName == "0" ? "0" : "PEX_REFERENCE_" + PEXSPICEIdentity.hex(referenceName)
        let nodeMap = try makeNodeMap(for: ir, referenceToken: referenceToken)
        let elementIDs = try makeElementIDs(for: ir)
        let subcircuit = try makeSubcircuitName(for: ir)
        var ports = ir.nets
            .flatMap { net in
                net.nodes.filter { $0.kind == .pin }.map { NodeRef(netName: net.name, nodeName: $0.name) }
            }
            .compactMap { nodeMap[$0] }
            .filter { $0 != "0" }
            .deduplicated()

        if referenceToken != "0" && ir.elements.contains(where: { $0.kind == .capacitor && $0.nodeB == nil }) {
            ports.append(referenceToken)
        }
        var identityNodes: [String: PEXSPICEIdentity.Node] = [:]
        for net in ir.nets {
            for node in net.nodes {
                let ref = NodeRef(netName: net.name, nodeName: node.name)
                guard let token = nodeMap[ref] else { throw PEXSPICEWriterError.invalidNodeName(node.name.value) }
                identityNodes[token] = PEXSPICEIdentity.Node(ref: ref, kind: node.kind)
            }
        }
        var kinds: [String: ElementKind] = [:]
        for element in ir.elements {
            guard let id = elementIDs[element.id] else { throw PEXSPICEWriterError.invalidElementIdentifier(element.id) }
            let prefix = element.kind == .resistor ? "R" : element.kind == .inductor ? "L" : "C"
            kinds["\(prefix)PEX_\(id)"] = element.kind
        }
        let identity = PEXSPICEIdentity(nodes: identityNodes, elementKinds: kinds, referenceName: referenceName, referenceToken: referenceToken)
        var lines: [String] = []
        lines.append("* PEX backannotation generated from ParasiticIR \(ir.version)")
        lines.append(try identity.comment())
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
                lines.append("RPEX_\(elementID) \(nodeA) \(try nodeToken(for: nodeB, nodeMap: nodeMap)) \(try checkedFormat(value, id: element.id))")
            case .capacitor:
                value = element.value * capacitanceScale(ir.units.capacitance)
                let nodeB: String
                if let ref = element.nodeB {
                    nodeB = try nodeToken(for: ref, nodeMap: nodeMap)
                } else {
                    nodeB = referenceToken
                }
                lines.append("CPEX_\(elementID) \(nodeA) \(nodeB) \(try checkedFormat(value, id: element.id))")
            case .coupling:
                guard let nodeB = element.nodeB else { throw PEXSPICEWriterError.missingEndpoint(element.id) }
                value = element.value * capacitanceScale(ir.units.capacitance)
                lines.append("CPEX_\(elementID) \(nodeA) \(try nodeToken(for: nodeB, nodeMap: nodeMap)) \(try checkedFormat(value, id: element.id))")
            case .inductor:
                guard let nodeB = element.nodeB else { throw PEXSPICEWriterError.missingEndpoint(element.id) }
                value = element.value
                lines.append("LPEX_\(elementID) \(nodeA) \(try nodeToken(for: nodeB, nodeMap: nodeMap)) \(try checkedFormat(value, id: element.id))")
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
            while !used.insert(candidate.lowercased()).inserted {
                candidate = "\(base)_\(suffix)"
                suffix += 1
            }
            guard result[element.id] == nil else { throw PEXSPICEWriterError.invalidElementIdentifier(element.id) }
            result[element.id] = candidate
        }
        return result
    }

    private func makeNodeMap(for ir: ParasiticIR, referenceToken: String) throws -> NodeMap {
        let refs = ir.nets.flatMap { net in
            net.nodes.map { NodeRef(netName: net.name, nodeName: $0.name) }
        }
        guard Set(ir.nets.map(\.name)).count == ir.nets.count, Set(refs).count == refs.count else {
            throw PEXSPICEWriterError.nodeIdentityCollision("Duplicate canonical net or node")
        }
        let counts = Dictionary(grouping: refs, by: { $0.nodeName.value.lowercased() }).mapValues(\.count)
        var map: [NodeRef: String] = [:]
        var owners: Set<String> = [referenceToken.lowercased(), "0"]
        for ref in refs {
            try validateNodeToken(ref.nodeName.value, original: ref.nodeName.value)
            guard !ref.netName.value.isEmpty else { throw PEXSPICEWriterError.invalidNodeName(ref.netName.value) }
            let raw = ref.nodeName.value
            let lower = raw.lowercased()
            let mustEncode = counts[lower] != 1 || lower == "0" || lower == "gnd"
                || lower == "gnd!" || lower == "vsubs" || lower.hasPrefix("pex_")
            let token = mustEncode ? PEXSPICEIdentity.encodedToken(ref) : raw
            guard owners.insert(token.lowercased()).inserted else {
                throw PEXSPICEWriterError.nodeIdentityCollision(token)
            }
            map[ref] = token
        }
        return NodeMap(values: map)
    }

    private func nodeToken(for ref: NodeRef, nodeMap: NodeMap) throws -> String {
        guard let token = nodeMap[ref] else {
            throw PEXSPICEWriterError.invalidNodeName("\(ref.netName.value):\(ref.nodeName.value)")
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

    private func checkedFormat(_ value: Double, id: String) throws -> String {
        guard value.isFinite else { throw PEXSPICEWriterError.nonFiniteValue(id) }
        return String(value)
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
