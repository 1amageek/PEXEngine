import Foundation
import PEXCore

public struct PEXSourceConnectivityChecker: Sendable {
    public init() {}

    public func check(
        sourceNetlistURL: URL,
        sourceNetlistFormat: NetlistFormat,
        ir: ParasiticIR
    ) throws -> PEXSourceConnectivityReport {
        guard sourceNetlistFormat == .spice || sourceNetlistFormat == .cdl || sourceNetlistFormat == .verilog else {
            return PEXSourceConnectivityReport(
                status: .warning,
                sourceNetlistFormat: sourceNetlistFormat,
                sourceNodeCount: 0,
                extractedPinNodeCount: 0,
                matchedPinNodeCount: 0,
                diagnostics: [
                    "Source-netlist connectivity checking is not implemented for format '\(sourceNetlistFormat.rawValue)'",
                ]
            )
        }

        let source: String
        do {
            source = try String(contentsOf: sourceNetlistURL, encoding: .utf8)
        } catch {
            throw PEXError.parseFailed(
                cornerID: ir.cornerID,
                message: "Failed to read source netlist for connectivity checking: \(sourceNetlistURL.lastPathComponent)",
                underlying: error
            )
        }

        let sourceNodes: [String]
        if sourceNetlistFormat == .verilog {
            let parsed = PEXVerilogConnectivityParser().parse(source)
            guard parsed.isUsable else {
                return PEXSourceConnectivityReport(
                    status: .warning,
                    sourceNetlistFormat: sourceNetlistFormat,
                    sourceNodeCount: parsed.sourceNodes.count,
                    extractedPinNodeCount: ir.nets.flatMap(\.nodes).filter { $0.kind == .pin }.count,
                    matchedPinNodeCount: 0,
                    sourceOnlyNodes: parsed.sourceNodes,
                    diagnostics: [
                        "Verilog connectivity parser could not establish a complete module boundary",
                    ] + parsed.diagnostics
                )
            }
            sourceNodes = parsed.sourceNodes
        } else {
            sourceNodes = parseSourceNodes(source)
        }
        let sourceAliases = Set(sourceNodes.flatMap(aliases(forSourceNode:)))
        let extractedPins = ir.nets
            .flatMap(\.nodes)
            .filter { $0.kind == .pin }
        guard !extractedPins.isEmpty else {
            return PEXSourceConnectivityReport(
                status: .warning,
                sourceNetlistFormat: sourceNetlistFormat,
                sourceNodeCount: sourceNodes.count,
                extractedPinNodeCount: 0,
                matchedPinNodeCount: 0,
                sourceOnlyNodes: sourceNodes,
                diagnostics: [
                    "Canonical ParasiticIR contains no pin nodes; source-netlist connectivity could not be proven",
                ]
            )
        }

        let unmatched = extractedPins.compactMap { node -> String? in
            let nodeAliases = aliases(forExtractedNode: node)
            return nodeAliases.isDisjoint(with: sourceAliases) ? node.name.value : nil
        }
        let matchedCount = extractedPins.count - unmatched.count
        let status: PEXSourceConnectivityStatus = unmatched.isEmpty ? .passed : .failed
        let extractedAliases = Set(extractedPins.flatMap(aliases(forExtractedNode:)))
        let matchedSourceAliases = extractedAliases.intersection(sourceAliases)
        let sourceOnlyNodes = sourceNodes.filter { node in
            aliases(forSourceNode: node).isDisjoint(with: matchedSourceAliases)
        }
        var diagnostics: [String] = []
        if !unmatched.isEmpty {
            diagnostics.append(
                "\(unmatched.count) extracted pin node(s) are absent from the source netlist"
            )
        }
        return PEXSourceConnectivityReport(
            status: status,
            sourceNetlistFormat: sourceNetlistFormat,
            sourceNodeCount: sourceNodes.count,
            extractedPinNodeCount: extractedPins.count,
            matchedPinNodeCount: matchedCount,
            unmatchedExtractedPinNodes: unmatched,
            sourceOnlyNodes: sourceOnlyNodes,
            diagnostics: diagnostics
        )
    }

    private func parseSourceNodes(_ source: String) -> [String] {
        var nodes: [String] = []
        var seen: Set<String> = []
        for rawLine in logicalLines(source) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("*") else { continue }
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = tokens.first else { continue }
            if first.caseInsensitiveCompare(".subckt") == .orderedSame {
                for token in tokens.dropFirst(2) {
                    let normalized = normalize(token)
                    guard !normalized.isEmpty,
                          !normalized.hasPrefix("params:"),
                          !isGround(normalized),
                          seen.insert(normalized).inserted
                    else { continue }
                    nodes.append(normalized)
                }
                continue
            }
            guard !first.hasPrefix(".") else { continue }
            let elementKind = first.first.map(String.init)?.lowercased() ?? ""
            let nodeCount: Int
            switch elementKind {
            case "r", "c", "l", "v", "i", "d", "b": nodeCount = 2
            case "q", "j": nodeCount = 3
            case "m": nodeCount = 4
            case "e", "f", "g", "h", "s", "w": nodeCount = 4
            case "x": nodeCount = max(0, tokens.count - 2)
            default: nodeCount = min(2, max(0, tokens.count - 1))
            }
            guard nodeCount > 0 else { continue }
            let candidateTokens = tokens.dropFirst().prefix(nodeCount)
            for token in candidateTokens {
                let normalized = normalize(token)
                guard !normalized.isEmpty, !isGround(normalized), seen.insert(normalized).inserted else {
                    continue
                }
                nodes.append(normalized)
            }
        }
        return nodes
    }

    private func logicalLines(_ source: String) -> [String] {
        var lines: [String] = []
        for rawLine in source.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("+"), !lines.isEmpty {
                lines[lines.count - 1] += " " + String(trimmed.dropFirst())
            } else {
                lines.append(rawLine)
            }
        }
        return lines
    }

    private func aliases(forSourceNode node: String) -> Set<String> {
        var result: Set<String> = [normalize(node)]
        appendLeafAliases(node, to: &result)
        return result
    }

    private func aliases(forExtractedNode node: ParasiticNode) -> Set<String> {
        var result: Set<String> = [normalize(node.name.value)]
        appendLeafAliases(node.name.value, to: &result)
        if let instancePath = node.instancePath?.value {
            let normalizedInstancePath = normalize(instancePath)
            if let suffix = node.name.value.split(whereSeparator: { $0 == ":" || $0 == "/" }).last {
                result.insert("\(normalizedInstancePath):\(normalize(String(suffix)))")
                result.insert("\(normalizedInstancePath)/\(normalize(String(suffix)))")
            }
        }
        return result
    }

    private func appendLeafAliases(_ value: String, to result: inout Set<String>) {
        let separators = CharacterSet(charactersIn: ":/")
        let components = value.components(separatedBy: separators).filter { !$0.isEmpty }
        if let leaf = components.last {
            result.insert(normalize(leaf))
        }
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\\\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func isGround(_ value: String) -> Bool {
        ["0", "gnd", "gnd!", "vss", "vsub", "vsubs"].contains(value)
    }
}
