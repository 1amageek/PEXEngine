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

        var elements: [ParasiticElement] = []
        var capIndex = 0
        var resIndex = 0
        // Per-net running totals; first-seen order preserved for deterministic output.
        var netOrder: [String] = []
        var seenNets: Set<String> = []
        var groundCap: [String: Double] = [:]
        var couplingCap: [String: Double] = [:]
        var resistance: [String: Double] = [:]

        func register(_ net: String) {
            if seenNets.insert(net).inserted {
                netOrder.append(net)
            }
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
                    register(signal)
                    groundCap[signal, default: 0] += value
                    elements.append(ParasiticElement(
                        id: "C\(capIndex)",
                        kind: .capacitor,
                        nodeA: ref(signal),
                        nodeB: nil,
                        value: value,
                        source: .extracted
                    ))
                    capIndex += 1
                } else {
                    guard includeCoupling else { continue }
                    register(nodeA)
                    register(nodeB)
                    // Attribute the coupling value to one net only (nodeA, the
                    // owner) — matching SPEFLowering, so per-net totals and their
                    // sum agree across both parsers feeding ParasiticIR.
                    couplingCap[nodeA, default: 0] += value
                    elements.append(ParasiticElement(
                        id: "C\(capIndex)",
                        kind: .coupling,
                        nodeA: ref(nodeA),
                        nodeB: ref(nodeB),
                        value: value,
                        source: .extracted
                    ))
                    capIndex += 1
                }
            } else { // resistor
                register(nodeA)
                register(nodeB)
                // Count the resistor once (on nodeA), as SPEFLowering does.
                resistance[nodeA, default: 0] += value
                elements.append(ParasiticElement(
                    id: "R\(resIndex)",
                    kind: .resistor,
                    nodeA: ref(nodeA),
                    nodeB: ref(nodeB),
                    value: value,
                    source: .extracted
                ))
                resIndex += 1
            }
        }

        let nets = netOrder.map { name in
            ParasiticNet(
                name: NetName(name),
                nodes: [ParasiticNode(name: NodeName(name), kind: .internal, instancePath: nil, coordinate: nil)],
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

    private func ref(_ name: String) -> NodeRef {
        NodeRef(netName: NetName(name), nodeName: NodeName(name))
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
