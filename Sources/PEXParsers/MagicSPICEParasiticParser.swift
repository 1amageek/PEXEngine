import Foundation
import PEXCore

/// Parses the parasitic SPICE netlist produced by Magic's `ext2spice` into the
/// canonical `ParasiticIR`.
///
/// Magic emits parasitic capacitors as `C<id> <nodeA> <nodeB> <value>` and, when
/// resistance extraction is enabled, resistors as `R<id> <nodeA> <nodeB> <value>`.
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
        guard let fileURL = raw.fileURLs.first else {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "No SPICE file found in raw output"
            )
        }
        let source: String
        do {
            source = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "Failed to read SPICE file: \(fileURL.lastPathComponent)",
                underlying: error
            )
        }

        // Coupling caps are dropped when the run does not request them, matching
        // MockParasiticGenerator (Magic's own `cthresh infinite` cannot do this —
        // it discards grounded caps too — so the filtering happens here).
        let includeCoupling = context.options.includeCouplingCaps

        // Coupling caps are dropped when the run does not request them, matching
        // MockParasiticGenerator.
        struct GroundCapRecord { let signal: String; let value: Double }
        struct PairRecord { let a: String; let b: String; let value: Double }
        var grounds: [GroundCapRecord] = []
        var couplings: [PairRecord] = []
        var resistors: [PairRecord] = []

        // First-seen node order, and a union-find over resistor endpoints so that
        // resistor-connected sub-nodes (Magic splits a net at resistors) collapse
        // into one net — matching SPEFLowering, where a net's resistors are
        // intra-net. Capacitors never merge nets (coupling is cross-net).
        var nodeOrder: [String] = []
        var seenNodes: Set<String> = []
        var parent: [String: String] = [:]
        func see(_ n: String) {
            if parent[n] == nil { parent[n] = n }
            if seenNodes.insert(n).inserted { nodeOrder.append(n) }
        }
        func find(_ x: String) -> String {
            var root = x
            while parent[root]! != root { root = parent[root]! }
            var cursor = x
            while parent[cursor]! != root { let next = parent[cursor]!; parent[cursor] = root; cursor = next }
            return root
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        for rawLine in source.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let first = line.first else { continue }
            // Skip comments, directives, and continuation lines.
            if first == "*" || first == "." || first == "+" { continue }
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 4 else { continue }

            let kind = first.lowercased()
            guard kind == "c" || kind == "r" else { continue } // ignore devices

            let nodeA = tokens[1]
            let nodeB = tokens[2]
            guard let value = Self.parseSPICEValue(tokens[3]) else {
                throw PEXError.parseFailed(
                    cornerID: context.cornerID,
                    message: "Unparseable value '\(tokens[3])' in line: \(line)"
                )
            }

            if kind == "c" {
                let aGround = isGround(nodeA)
                let bGround = isGround(nodeB)
                if aGround && bGround { continue }
                if aGround || bGround {
                    let signal = aGround ? nodeB : nodeA
                    see(signal)
                    grounds.append(GroundCapRecord(signal: signal, value: value))
                } else {
                    guard includeCoupling else { continue }
                    see(nodeA); see(nodeB)
                    couplings.append(PairRecord(a: nodeA, b: nodeB, value: value))
                }
            } else { // resistor
                see(nodeA); see(nodeB)
                union(nodeA, nodeB)
                resistors.append(PairRecord(a: nodeA, b: nodeB, value: value))
            }
        }

        // Net name per node = the lexicographically smallest node in its
        // resistor-connected component (the clean base name, e.g. "Y" over
        // "Y_ext_1#"). Nodes with no resistors are their own singleton net, so the
        // capacitance-only case is unchanged (one net per node).
        var componentNodes: [String: [String]] = [:]
        for n in nodeOrder { componentNodes[find(n), default: []].append(n) }
        var netNameOf: [String: String] = [:]
        for (_, nodes) in componentNodes {
            let netName = nodes.min() ?? nodes[0]
            for n in nodes { netNameOf[n] = netName }
        }
        func netName(_ n: String) -> String { netNameOf[n] ?? n }
        func nodeRef(_ n: String) -> NodeRef {
            NodeRef(netName: NetName(netName(n)), nodeName: NodeName(n))
        }

        var elements: [ParasiticElement] = []
        var capIndex = 0
        var resIndex = 0
        var groundCap: [String: Double] = [:]
        var couplingCap: [String: Double] = [:]
        var resistance: [String: Double] = [:]

        for g in grounds {
            elements.append(ParasiticElement(
                id: "C\(capIndex)", kind: .capacitor,
                nodeA: nodeRef(g.signal), nodeB: nil, value: g.value, source: .extracted
            ))
            capIndex += 1
            groundCap[netName(g.signal), default: 0] += g.value
        }
        for c in couplings {
            elements.append(ParasiticElement(
                id: "C\(capIndex)", kind: .coupling,
                nodeA: nodeRef(c.a), nodeB: nodeRef(c.b), value: c.value, source: .extracted
            ))
            capIndex += 1
            // Attribute coupling to one net only (a's net), matching SPEFLowering.
            couplingCap[netName(c.a), default: 0] += c.value
        }
        for r in resistors {
            elements.append(ParasiticElement(
                id: "R\(resIndex)", kind: .resistor,
                nodeA: nodeRef(r.a), nodeB: nodeRef(r.b), value: r.value, source: .extracted
            ))
            resIndex += 1
            // Count the resistor once (on a's net), matching SPEFLowering.
            resistance[netName(r.a), default: 0] += r.value
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

        return ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: context.cornerID,
            units: .canonical,
            nets: nets,
            elements: elements,
            metadata: [
                "sourceFormat": "magic-spice",
                "sourceFile": fileURL.lastPathComponent,
            ]
        )
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
        if suffix.hasPrefix("meg") { multiplier = 1e6 }
        else if suffix.hasPrefix("f") { multiplier = 1e-15 }
        else if suffix.hasPrefix("p") { multiplier = 1e-12 }
        else if suffix.hasPrefix("n") { multiplier = 1e-9 }
        else if suffix.hasPrefix("u") { multiplier = 1e-6 }
        else if suffix.hasPrefix("m") { multiplier = 1e-3 }
        else if suffix.hasPrefix("k") { multiplier = 1e3 }
        else if suffix.hasPrefix("g") { multiplier = 1e9 }
        else if suffix.hasPrefix("t") { multiplier = 1e12 }
        else { return nil }
        return mantissa * multiplier
    }
}
