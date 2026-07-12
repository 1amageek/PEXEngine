import Foundation
import PEXCore

/// Parses the parasitic SPICE netlist produced by Magic's `ext2spice` into the
/// canonical `ParasiticIR`.
///
/// Magic emits parasitic capacitors as `C<id> <nodeA> <nodeB> <value>` and, when
/// resistance extraction is enabled, resistors as `R<id> <nodeA> <nodeB> <value>`.
/// Some extracted SPICE/DSPF producers also emit inductors as
/// `L<id> <nodeA> <nodeB> <value>`, which are retained in the canonical IR when
/// full RC extraction is requested.
/// A capacitor whose second node is the substrate/global-ground node becomes a
/// grounded `capacitor` (nodeB == nil); a capacitor between two signal nets
/// becomes a `coupling` element. Device lines (`X`/`M`/...) and directives are
/// ignored — only parasitics are lowered. Each distinct signal node is its own
/// single-node net, which satisfies `ParasiticIRValidator`'s membership rules.
public struct MagicSPICEParasiticParser: PEXParserProtocol {

    public let format: PEXOutputFormat = .spice

    /// Node names treated as the global ground / substrate (a capacitor to one of
    /// these is a grounded capacitor, not coupling). Matched case-insensitively.
    /// Intentionally narrow: it holds only the substrate / global-ground node, not
    /// design ground rails like Sky130's `VGND`/`VPWR`, which are real nets whose
    /// capacitors must stay coupling.
    public let groundNodes: Set<String>

    public init(groundNodes: Set<String> = ["VSUBS", "0", "gnd!"]) {
        self.groundNodes = Set(groundNodes.map { $0.lowercased() })
    }

    private func isGround(_ node: String) -> Bool {
        groundNodes.contains(node.lowercased())
    }

    public func parse(_ raw: PEXRawOutput, context: PEXParseContext) throws -> ParasiticIR {
        try validateFormat(raw.format, context: context)
        let fileURL = try selectedFile(from: raw, context: context)
        let source = try readSource(from: fileURL, context: context)
        let records = try parseRecords(source: source, context: context)
        return buildIR(
            records: records,
            sourceFileName: fileURL.lastPathComponent,
            context: context
        )
    }

    private func validateFormat(_ rawFormat: PEXOutputFormat, context: PEXParseContext) throws {
        guard rawFormat == format else {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "Magic SPICE parser received raw output format '\(rawFormat.rawValue)'"
            )
        }
    }

    private func selectedFile(from raw: PEXRawOutput, context: PEXParseContext) throws -> URL {
        guard let fileURL = raw.fileURLs.first else {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "No SPICE file found in raw output"
            )
        }
        return fileURL
    }

    private func readSource(from fileURL: URL, context: PEXParseContext) throws -> String {
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "Failed to read SPICE file: \(fileURL.lastPathComponent)",
                underlying: error
            )
        }
    }

    private func parseRecords(source: String, context: PEXParseContext) throws -> MagicSPICERecords {
        let options = context.options
        var records = MagicSPICERecords()
        for rawLine in source.split(whereSeparator: \.isNewline) {
            if let line = try parseElementLine(String(rawLine), context: context) {
                append(line, to: &records, options: options)
            }
        }
        return records
    }

    private func parseElementLine(_ rawLine: String, context: PEXParseContext) throws -> MagicSPICEElementLine? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard let first = line.first else { return nil }
        if first == "*" || first == "." || first == "+" { return nil }
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let kind = MagicSPICEElementKind(rawPrefix: first) else { return nil }
        guard let elementTokens = MagicSPICEElementTokens(tokens: tokens) else {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "Truncated \(kind.rawName) element line requires name, two nodes, and value: \(line)"
            )
        }
        guard let value = Self.parseSPICEValue(elementTokens.valueToken) else {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "Unparseable value '\(elementTokens.valueToken)' in line: \(line)"
            )
        }

        return MagicSPICEElementLine(
            kind: kind,
            nodeA: elementTokens.nodeA,
            nodeB: elementTokens.nodeB,
            value: value
        )
    }

    private func append(
        _ line: MagicSPICEElementLine,
        to records: inout MagicSPICERecords,
        options: PEXRunOptions
    ) {
        switch line.kind {
        case .capacitor:
            appendCapacitor(line, to: &records, options: options)
        case .resistor:
            records.connectivity.see(line.nodeA)
            records.connectivity.see(line.nodeB)
            records.connectivity.union(line.nodeA, line.nodeB)
            guard shouldIncludeResistance(line.value, options: options) else { return }
            records.resistors.append(MagicPairRecord(a: line.nodeA, b: line.nodeB, value: line.value))
        case .inductor:
            records.connectivity.see(line.nodeA)
            records.connectivity.see(line.nodeB)
            records.connectivity.union(line.nodeA, line.nodeB)
            guard shouldIncludeInductance(options: options) else { return }
            records.inductors.append(MagicPairRecord(a: line.nodeA, b: line.nodeB, value: line.value))
        }
    }

    private func appendCapacitor(
        _ line: MagicSPICEElementLine,
        to records: inout MagicSPICERecords,
        options: PEXRunOptions
    ) {
        let aGround = isGround(line.nodeA)
        let bGround = isGround(line.nodeB)
        if aGround && bGround { return }
        if aGround || bGround {
            let signal = aGround ? line.nodeB : line.nodeA
            records.connectivity.see(signal)
            guard shouldIncludeCapacitance(line.value, options: options) else { return }
            records.grounds.append(MagicGroundCapRecord(signal: signal, value: line.value))
        } else {
            records.connectivity.see(line.nodeA)
            records.connectivity.see(line.nodeB)
            guard options.includeCouplingCaps else { return }
            guard shouldIncludeCapacitance(line.value, options: options) else { return }
            records.couplings.append(MagicPairRecord(a: line.nodeA, b: line.nodeB, value: line.value))
        }
    }

    private func buildIR(
        records: MagicSPICERecords,
        sourceFileName: String,
        context: PEXParseContext
    ) -> ParasiticIR {
        let netNameOf = records.connectivity.netNameMap()
        let nodeOrder = records.connectivity.nodeOrder

        var elements: [ParasiticElement] = []
        var capIndex = 0
        var resIndex = 0
        var indIndex = 0
        var groundCap: [String: Double] = [:]
        var couplingCap: [String: Double] = [:]
        var resistance: [String: Double] = [:]

        func netName(_ n: String) -> String { netNameOf[n] ?? n }
        func nodeRef(_ n: String) -> NodeRef {
            NodeRef(netName: NetName(netName(n)), nodeName: NodeName(n))
        }

        for g in records.grounds {
            elements.append(ParasiticElement(
                id: "C\(capIndex)", kind: .capacitor,
                nodeA: nodeRef(g.signal), nodeB: nil, value: g.value, source: .extracted
            ))
            capIndex += 1
            groundCap[netName(g.signal), default: 0] += g.value
        }
        for c in records.couplings {
            elements.append(ParasiticElement(
                id: "C\(capIndex)", kind: .coupling,
                nodeA: nodeRef(c.a), nodeB: nodeRef(c.b), value: c.value, source: .extracted
            ))
            capIndex += 1
            // Attribute coupling to one net only (a's net), matching SPEFLowering.
            couplingCap[netName(c.a), default: 0] += c.value
        }
        for r in records.resistors {
            elements.append(ParasiticElement(
                id: "R\(resIndex)", kind: .resistor,
                nodeA: nodeRef(r.a), nodeB: nodeRef(r.b), value: r.value, source: .extracted
            ))
            resIndex += 1
            // Count the resistor once (on a's net), matching SPEFLowering.
            resistance[netName(r.a), default: 0] += r.value
        }
        for l in records.inductors {
            elements.append(ParasiticElement(
                id: "L\(indIndex)", kind: .inductor,
                nodeA: nodeRef(l.a), nodeB: nodeRef(l.b), value: l.value, source: .extracted
            ))
            indIndex += 1
        }

        // Nets in first-seen order of their net name; each carries all its nodes.
        var netOrder: [String] = []
        var seenNets: Set<String> = []
        for n in nodeOrder where seenNets.insert(netName(n)).inserted {
            netOrder.append(netName(n))
        }
        let nets = netOrder.map { name in
            ParasiticNet(
                name: NetName(name),
                nodes: nodeOrder.filter { netName($0) == name }.map {
                    ParasiticNode(name: NodeName($0), kind: .internal, instancePath: nil, coordinate: nil)
                },
                totalGroundCapF: groundCap[name] ?? 0,
                totalCouplingCapF: couplingCap[name] ?? 0,
                totalResistanceOhm: resistance[name] ?? 0
            )
        }

        var metadata = [
            "sourceFormat": "magic-spice",
            "sourceFile": sourceFileName,
        ]
        if let topCell = context.topCell,
           !topCell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata["topCell"] = topCell
        }
        return ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: context.cornerID,
            units: .canonical,
            nets: nets,
            elements: elements,
            metadata: metadata
        )
    }

    private func shouldIncludeCapacitance(_ value: Double, options: PEXRunOptions) -> Bool {
        guard options.extractMode != .rOnly else { return false }
        if let minCapacitanceF = options.minCapacitanceF, value < minCapacitanceF {
            return false
        }
        return true
    }

    private func shouldIncludeResistance(_ value: Double, options: PEXRunOptions) -> Bool {
        guard options.extractMode != .cOnly else { return false }
        if let minResistanceOhm = options.minResistanceOhm, value < minResistanceOhm {
            return false
        }
        return true
    }

    private func shouldIncludeInductance(options: PEXRunOptions) -> Bool {
        options.extractMode == .rc
    }

    /// Parses a SPICE-style number with an optional engineering suffix into a
    /// canonical SI value. Returns nil for an unparseable mantissa or an
    /// unrecognized suffix (the caller fails loudly rather than mis-scaling).
    static func parseSPICEValue(_ token: String) -> Double? {
        let s = token.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        var end = s.startIndex
        var seenDigit = false
        var i = s.startIndex
        loop: while i < s.endIndex {
            let c = s[i]
            if c.isNumber {
                seenDigit = true
                i = s.index(after: i)
            } else if c == "." || c == "+" || c == "-" {
                i = s.index(after: i)
            } else if (c == "e" || c == "E") && seenDigit {
                var j = s.index(after: i)
                if j < s.endIndex, s[j] == "+" || s[j] == "-" { j = s.index(after: j) }
                guard j < s.endIndex, s[j].isNumber else { break loop }
                i = j
                while i < s.endIndex, s[i].isNumber { i = s.index(after: i) }
            } else {
                break loop
            }
            end = i
        }
        guard end > s.startIndex else { return nil }
        guard let mantissa = Double(String(s[s.startIndex..<end])) else { return nil }

        let suffix = String(s[end...]).lowercased()
        if suffix.isEmpty { return mantissa }
        let multiplier: Double
        switch suffix {
        case "meg": multiplier = 1e6
        case "t": multiplier = 1e12
        case "g": multiplier = 1e9
        case "k": multiplier = 1e3
        case "m": multiplier = 1e-3
        case "u": multiplier = 1e-6
        case "n": multiplier = 1e-9
        case "p": multiplier = 1e-12
        case "f": multiplier = 1e-15
        case "tf": multiplier = 1e12
        case "gf": multiplier = 1e9
        case "mf": multiplier = 1e-3
        case "uf": multiplier = 1e-6
        case "nf": multiplier = 1e-9
        case "pf": multiplier = 1e-12
        case "ff": multiplier = 1e-15
        default: return nil
        }
        return mantissa * multiplier
    }
}

private enum MagicSPICEElementKind {
    case capacitor
    case resistor
    case inductor

    var rawName: String {
        switch self {
        case .capacitor:
            return "capacitor"
        case .resistor:
            return "resistor"
        case .inductor:
            return "inductor"
        }
    }

    init?(rawPrefix: Character) {
        switch rawPrefix.lowercased() {
        case "c":
            self = .capacitor
        case "r":
            self = .resistor
        case "l":
            self = .inductor
        default:
            return nil
        }
    }
}

private struct MagicSPICEElementLine {
    var kind: MagicSPICEElementKind
    var nodeA: String
    var nodeB: String
    var value: Double
}

private struct MagicSPICEElementTokens {
    var nodeA: String
    var nodeB: String
    var valueToken: String

    init?(tokens: [String]) {
        var iterator = tokens.makeIterator()
        guard iterator.next() != nil,
              let nodeA = iterator.next(),
              let nodeB = iterator.next(),
              let valueToken = iterator.next() else {
            return nil
        }
        self.nodeA = nodeA
        self.nodeB = nodeB
        self.valueToken = valueToken
    }
}

private struct MagicSPICERecords {
    var grounds: [MagicGroundCapRecord] = []
    var couplings: [MagicPairRecord] = []
    var resistors: [MagicPairRecord] = []
    var inductors: [MagicPairRecord] = []
    var connectivity = MagicNodeConnectivity()
}

private struct MagicGroundCapRecord {
    var signal: String
    var value: Double
}

private struct MagicPairRecord {
    var a: String
    var b: String
    var value: Double
}

private struct MagicNodeConnectivity {
    private(set) var nodeOrder: [String] = []
    private var seenNodes: Set<String> = []
    private var parent: [String: String] = [:]

    mutating func see(_ node: String) {
        if parent[node] == nil {
            parent[node] = node
        }
        if seenNodes.insert(node).inserted {
            nodeOrder.append(node)
        }
    }

    mutating func union(_ lhs: String, _ rhs: String) {
        let lhsRoot = find(lhs)
        let rhsRoot = find(rhs)
        if lhsRoot != rhsRoot {
            parent[rhsRoot] = lhsRoot
        }
    }

    func netNameMap() -> [String: String] {
        var copy = self
        return copy.makeNetNameMap()
    }

    private mutating func makeNetNameMap() -> [String: String] {
        var componentNodes: [String: [String]] = [:]
        for node in nodeOrder {
            componentNodes[find(node), default: []].append(node)
        }

        var netNameOf: [String: String] = [:]
        for (_, nodes) in componentNodes {
            guard let netName = nodes.min() else { continue }
            for node in nodes {
                netNameOf[node] = netName
            }
        }
        return netNameOf
    }

    private mutating func find(_ node: String) -> String {
        if parent[node] == nil {
            parent[node] = node
        }
        var root = node
        while let next = parent[root], next != root {
            root = next
        }
        var cursor = node
        while let next = parent[cursor], next != root {
            parent[cursor] = root
            cursor = next
        }
        return root
    }
}
