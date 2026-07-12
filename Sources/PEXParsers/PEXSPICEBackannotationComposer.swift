import Foundation
import PEXCore

/// Composes a canonical PEX fragment into a source SPICE deck while keeping
/// the source hierarchy and its terminal names intact.
public struct PEXSPICEBackannotationComposer: Sendable {
    private let options: PEXSPICEBackannotationOptions

    public init(options: PEXSPICEBackannotationOptions = PEXSPICEBackannotationOptions()) {
        self.options = options
    }

    public func compose(sourceNetlist: String, ir: ParasiticIR) throws -> String {
        let sourceLines = sourceNetlist
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard sourceLines.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw PEXSPICEBackannotationError.emptySourceNetlist
        }

        let subcircuitName = options.subcircuitName ?? defaultSubcircuitName(for: ir)
        let writer = PEXSPICEWriter(options: PEXSPICEWriterOptions(subcircuitName: subcircuitName))
        let fragment: String
        do {
            fragment = try writer.write(ir)
        } catch let error as PEXSPICEWriterError {
            throw PEXSPICEBackannotationError.writer(error)
        } catch {
            throw PEXSPICEBackannotationError.writer(.invalidElementIdentifier(String(describing: error)))
        }

        let declaration = try generatedDeclaration(in: fragment)
        guard !declaration.ports.isEmpty else {
            throw PEXSPICEBackannotationError.missingGeneratedPorts
        }
        guard !sourceSubcircuitNames(sourceLines).contains(declaration.name.lowercased()) else {
            throw PEXSPICEBackannotationError.subcircuitNameCollision(declaration.name)
        }
        let sourceNodes = sourceNodeAliases(sourceLines)
        var connectedPorts: [String] = []
        if options.requirePortMatches {
            for port in declaration.ports where port != "0" {
                guard let sourcePort = sourceNodes[port.lowercased()] else {
                    throw PEXSPICEBackannotationError.unmatchedSourcePort(port)
                }
                connectedPorts.append(sourcePort)
            }
        } else {
            connectedPorts = declaration.ports.filter { $0 != "0" }
        }

        let sourceIdentifiers = sourceElementIdentifiers(sourceLines)
        let instanceName = try resolveInstanceName(
            preferred: options.instanceName ?? "XPEX_\(sanitizeIdentifier(ir.cornerID.value))",
            sourceIdentifiers: sourceIdentifiers
        )
        let instanceLine = "\(instanceName)\(connectedPorts.isEmpty ? "" : " \(connectedPorts.joined(separator: " "))") \(declaration.name)"

        var outputLines = sourceLines
        let instanceIndex = try insertionIndexForInstance(in: outputLines)
        outputLines.insert(instanceLine, at: instanceIndex)

        let fragmentLines = fragment
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let fragmentIndex = endDirectiveIndex(in: outputLines) ?? outputLines.count
        outputLines.insert(contentsOf: ["", "* --- PEX canonical backannotation ---"] + fragmentLines, at: fragmentIndex)
        return outputLines.joined(separator: "\n") + "\n"
    }

    public func compose(sourceNetlistURL: URL, ir: ParasiticIR) throws -> String {
        let source: String
        do {
            source = try String(contentsOf: sourceNetlistURL, encoding: .utf8)
        } catch {
            throw PEXSPICEBackannotationError.sourceReadFailed(sourceNetlistURL.path(percentEncoded: false))
        }
        return try compose(sourceNetlist: source, ir: ir)
    }

    public func write(sourceNetlist: String, ir: ParasiticIR, to url: URL) throws {
        let composed = try compose(sourceNetlist: sourceNetlist, ir: ir)
        do {
            try Data(composed.utf8).write(to: url, options: .atomic)
        } catch {
            throw PEXSPICEBackannotationError.writeFailed(url.path(percentEncoded: false))
        }
    }

    private struct GeneratedDeclaration: Sendable {
        let name: String
        let ports: [String]
    }

    private func generatedDeclaration(in fragment: String) throws -> GeneratedDeclaration {
        for line in fragment.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.count >= 2,
                  tokens[0].lowercased() == ".subckt" else {
                continue
            }
            return GeneratedDeclaration(name: tokens[1], ports: Array(tokens.dropFirst(2)))
        }
        throw PEXSPICEBackannotationError.missingGeneratedSubcircuit
    }

    private func insertionIndexForInstance(in lines: [String]) throws -> Int {
        if let topCell = options.topCell {
            let normalizedTopCell = topCell.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedTopCell.isEmpty else {
                throw PEXSPICEBackannotationError.topCellNotFound(topCell)
            }
            var stack: [(name: String, start: Int)] = []
            for (index, line) in lines.enumerated() {
                let tokens = directiveTokens(line)
                guard let directive = tokens.first else { continue }
                if directive == ".subckt", tokens.count >= 2 {
                    stack.append((tokens[1], index))
                } else if directive == ".ends",
                          let active = stack.popLast(),
                          active.name.caseInsensitiveCompare(normalizedTopCell) == .orderedSame {
                    return index
                }
            }
            throw PEXSPICEBackannotationError.topCellNotFound(normalizedTopCell)
        }
        return endDirectiveIndex(in: lines) ?? lines.count
    }

    private func endDirectiveIndex(in lines: [String]) -> Int? {
        lines.lastIndex { directiveTokens($0).first == ".end" }
    }

    private func directiveTokens(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("*"), !trimmed.hasPrefix(";") else {
            return []
        }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private func sourceNodeAliases(_ lines: [String]) -> [String: String] {
        var nodes: [String: String] = [:]
        func add(_ token: String) {
            nodes[token.lowercased(), default: token] = token
        }
        for line in lines {
            let tokens = directiveTokens(line)
            guard let first = tokens.first else { continue }
            if first.lowercased() == ".subckt" {
                for token in tokens.dropFirst(2) {
                    add(token)
                }
                continue
            }
            if first.lowercased() == ".global" {
                for token in tokens.dropFirst() {
                    add(token)
                }
                continue
            }
            guard !first.hasPrefix(".") else { continue }
            let element = first.first?.uppercased() ?? ""
            let nodeIndices: [Int]
            switch element {
            case "R", "C", "L", "V", "I", "D", "B", "W": nodeIndices = [1, 2]
            case "Q": nodeIndices = [1, 2, 3, 4]
            case "M": nodeIndices = [1, 2, 3, 4]
            case "E", "G": nodeIndices = [1, 2, 3, 4]
            case "F", "H": nodeIndices = [1, 2]
            case "X": nodeIndices = Array(1..<max(1, tokens.count - 1))
            default: nodeIndices = Array(1..<tokens.count)
            }
            for index in nodeIndices where index < tokens.count {
                let token = tokens[index]
                guard !token.contains("=") else { continue }
                add(token)
            }
            if element == "X" {
                for token in tokens.dropFirst().dropLast() {
                    add(token)
                }
            }
        }
        return nodes
    }

    private func sourceElementIdentifiers(_ lines: [String]) -> Set<String> {
        Set(lines.compactMap { line in
            let tokens = directiveTokens(line)
            guard let identifier = tokens.first, !identifier.hasPrefix(".") else { return nil }
            return identifier
        })
    }

    private func sourceSubcircuitNames(_ lines: [String]) -> Set<String> {
        Set(lines.compactMap { line in
            let tokens = directiveTokens(line)
            guard tokens.first?.lowercased() == ".subckt", tokens.count >= 2 else {
                return nil
            }
            return tokens[1].lowercased()
        })
    }

    private func resolveInstanceName(preferred: String, sourceIdentifiers: Set<String>) throws -> String {
        let sanitized = sanitizeIdentifier(preferred)
        guard !sanitized.isEmpty else {
            throw PEXSPICEBackannotationError.instanceNameCollision(preferred)
        }
        if !sourceIdentifiers.contains(sanitized) {
            return sanitized
        }
        var suffix = 2
        while sourceIdentifiers.contains("\(sanitized)_\(suffix)") {
            suffix += 1
        }
        return "\(sanitized)_\(suffix)"
    }

    private func defaultSubcircuitName(for ir: ParasiticIR) -> String {
        let topCell = ir.metadata["topCell"] ?? "TOP"
        return "PEX_\(topCell)_\(ir.cornerID.value)"
    }

    private func sanitizeIdentifier(_ value: String) -> String {
        let mapped = value.map { character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}
