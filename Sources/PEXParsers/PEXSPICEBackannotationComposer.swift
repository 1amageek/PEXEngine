import Foundation
import PEXCore

/// Composes a canonical PEX fragment into a source SPICE deck while keeping
/// the source hierarchy and its terminal names intact.
public struct PEXSPICEBackannotationComposer: Sendable {
    private let options: PEXSPICEBackannotationOptions
    private let scope: PEXParserResourceScope?

    public init(options: PEXSPICEBackannotationOptions = PEXSPICEBackannotationOptions()) {
        self.options = options; self.scope = nil
    }

    private init(options: PEXSPICEBackannotationOptions, scope: PEXParserResourceScope) {
        self.options = options; self.scope = scope
    }

    public func compose(sourceNetlist: String, ir: ParasiticIR) throws -> String {
        try composeValue(sourceNetlist: sourceNetlist, ir: ir)
    }

    public func compose(sourceNetlist: String, ir: ParasiticIR,
                        control: any PEXParserResourceControlling)
        throws -> (value: String, retention: PEXParserRetention) {
        let scope = try PEXParserResourceScope(control: control)
        let value = try Self(options: options, scope: scope).composeValue(sourceNetlist: sourceNetlist, ir: ir)
        return (value, scope.retention)
    }

    private func composeValue(sourceNetlist: String, ir: ParasiticIR) throws -> String {
        try scope?.check()
        let sourceLines = try PEXSPICEConstruction.lines(sourceNetlist, scope: scope)
        var nonempty = false
        for line in sourceLines {
            try scope?.check()
            if !(try trimmed(line)).isEmpty { nonempty = true; break }
        }
        guard nonempty else { throw try PEXSPICEConstruction.failure(bytes: 0, scope: scope) { PEXSPICEBackannotationError.emptySourceNetlist } }
        let tokens = try sourceTokens(sourceLines)
        let subcircuitName = try options.subcircuitName ?? PEXSPICEConstruction.text(
            "PEX_", ir.metadata["topCell"] ?? "TOP", "_", ir.cornerID.value, scope: scope)
        let writer = PEXSPICEWriter(options: PEXSPICEWriterOptions(subcircuitName: subcircuitName))
        let fragment: String
        if let scope {
            // Writer source failures already retain this exact operation anchor;
            // callback failures must not be classified by their dynamic type.
            fragment = try writer.write(ir, scope: scope, outputKind: .temporary)
        } else {
            do { fragment = try writer.write(ir) }
            catch let error as PEXSPICEWriterError { throw PEXSPICEBackannotationError.writer(error) }
            catch { throw PEXSPICEBackannotationError.writer(.invalidElementIdentifier(String(describing: error))) }
        }
        let fragmentLines = try PEXSPICEConstruction.lines(fragment, scope: scope)
        let declaration = try generatedDeclaration(in: fragmentLines)
        guard !declaration.ports.isEmpty else { throw try PEXSPICEConstruction.failure(bytes: 0, scope: scope) { PEXSPICEBackannotationError.missingGeneratedPorts } }
        let names = try sourceSubcircuitNames(tokens)
        guard !(names.contains(try PEXSPICEConstruction.lower(declaration.name, scope: scope))) else {
            throw try PEXSPICEConstruction.failure(bytes: declaration.name.utf8.count, scope: scope) { PEXSPICEBackannotationError.subcircuitNameCollision(declaration.name) }
        }
        let sourceNodes = try sourceNodeAliases(tokens)
        let identity: PEXSPICEIdentity?
        if let scope { identity = try PEXSPICEIdentity.read(fragment, cornerID: ir.cornerID, scope: scope) }
        else { identity = try PEXSPICEIdentity.read(fragment, cornerID: ir.cornerID) }
        var pinCount = 0
        for net in ir.nets {
            for node in net.nodes {
                try scope?.check()
                if node.kind == .pin { pinCount = try PEXParserStorageSize.add(pinCount, 1) }
            }
        }
        // Only multiplicity is needed; retain no grouping arrays of NodeRef.
        try PEXSPICEConstruction.dictionary(String.self, Int.self, count: pinCount, scope: scope)
        var pinOwners: [String: Int] = [:]; pinOwners.reserveCapacity(pinCount)
        for net in ir.nets {
            for node in net.nodes {
                try scope?.check()
                if node.kind == .pin { pinOwners[try PEXSPICEConstruction.lower(node.name.value, scope: scope), default: 0] += 1 }
            }
        }
        try PEXSPICEConstruction.array(String.self, count: declaration.ports.count, scope: scope)
        var connectedPorts: [String] = []; connectedPorts.reserveCapacity(declaration.ports.count)
        for port in declaration.ports where port != "0" {
            try scope?.check()
            let original = identity?.nodes[port]?.ref.nodeName.value
                ?? (port == identity?.referenceToken ? identity?.referenceName : nil) ?? port
            if options.requirePortMatches {
                let key = try PEXSPICEConstruction.lower(original, scope: scope)
                guard (pinOwners[key] ?? 0) <= 1, let sourcePort = sourceNodes[key] else {
                    throw try PEXSPICEConstruction.failure(bytes: original.utf8.count, scope: scope) { PEXSPICEBackannotationError.unmatchedSourcePort(original) }
                }
                connectedPorts.append(sourcePort)
            } else { connectedPorts.append(original) }
        }
        if !options.requirePortMatches {
            try PEXSPICEConstruction.set(String.self, count: connectedPorts.count, scope: scope)
            var seen: Set<String> = []; seen.reserveCapacity(connectedPorts.count)
            for port in connectedPorts {
                try scope?.check()
                guard seen.insert(try PEXSPICEConstruction.lower(port, scope: scope)).inserted else {
                    throw try PEXSPICEConstruction.failure(bytes: 0, scope: scope) { PEXSPICEBackannotationError.unmatchedSourcePort("Ambiguous scoped terminal binding") }
                }
            }
        }
        let sourceIdentifiers = try sourceElementIdentifiers(tokens)
        let preferred = try options.instanceName ?? PEXSPICEConstruction.text(
            "XPEX_", try PEXSPICEConstruction.sanitize(ir.cornerID.value, scope: scope), scope: scope)
        let instanceName = try resolveInstanceName(preferred: preferred, sourceIdentifiers: sourceIdentifiers)
        let portText = try PEXSPICEConstruction.join(connectedPorts, separator: " ", scope: scope)
        let portSuffix = portText.isEmpty ? "" : try PEXSPICEConstruction.text(" ", portText, scope: scope)
        let instanceLine = try PEXSPICEConstruction.text(instanceName, portSuffix, " ", declaration.name, scope: scope)
        let instanceIndex = try insertionIndexForInstance(in: tokens)
        let intermediateCount = try PEXParserStorageSize.add(sourceLines.count, 1)
        try PEXSPICEConstruction.array(String.self, count: intermediateCount, scope: scope)
        var intermediate: [String] = []; intermediate.reserveCapacity(intermediateCount)
        for index in 0...sourceLines.count {
            try scope?.check()
            if index == instanceIndex { intermediate.append(instanceLine) }
            if index < sourceLines.count { intermediate.append(sourceLines[index]) }
        }
        let fragmentIndex: Int
        if let end = try endDirectiveIndex(in: tokens) { fragmentIndex = end >= instanceIndex ? end + 1 : end }
        else { fragmentIndex = intermediate.count }
        let additions = try PEXParserStorageSize.add(fragmentLines.count, 2)
        let outputCount = try PEXParserStorageSize.add(intermediate.count, additions)
        try PEXSPICEConstruction.array(String.self, count: outputCount, scope: scope)
        var output: [String] = []; output.reserveCapacity(outputCount)
        for index in 0...intermediate.count {
            try scope?.check()
            if index == fragmentIndex {
                output.append(""); output.append("* --- PEX canonical backannotation ---")
                for line in fragmentLines { try scope?.check(); output.append(line) }
            }
            if index < intermediate.count { output.append(intermediate[index]) }
        }
        return try PEXSPICEConstruction.join(output, separator: "\n", trailing: "\n", kind: .retained, scope: scope)
    }

    public func compose(sourceNetlistURL: URL, ir: ParasiticIR) throws -> String {
        let source: String
        do { source = try String(contentsOf: sourceNetlistURL, encoding: .utf8) }
        catch { throw PEXSPICEBackannotationError.sourceReadFailed(sourceNetlistURL.path(percentEncoded: false)) }
        return try compose(sourceNetlist: source, ir: ir)
    }

    public func write(sourceNetlist: String, ir: ParasiticIR, to url: URL) throws {
        let composed = try compose(sourceNetlist: sourceNetlist, ir: ir)
        do { try Data(composed.utf8).write(to: url, options: .atomic) }
        catch { throw PEXSPICEBackannotationError.writeFailed(url.path(percentEncoded: false)) }
    }

    private struct GeneratedDeclaration: Sendable { let name: String; let ports: [String] }

    private func generatedDeclaration(in lines: [String]) throws -> GeneratedDeclaration {
        for line in lines {
            try scope?.check()
            let tokens = try PEXSPICEConstruction.words(line, scope: scope)
            guard tokens.count >= 2 else { continue }
            guard try PEXSPICEConstruction.lower(tokens[0], scope: scope) == ".subckt" else { continue }
            try PEXSPICEConstruction.array(String.self, count: tokens.count - 2, scope: scope)
            var ports: [String] = []; ports.reserveCapacity(tokens.count - 2)
            for index in 2..<tokens.count { try scope?.check(); ports.append(tokens[index]) }
            return GeneratedDeclaration(name: tokens[1], ports: ports)
        }
        throw try PEXSPICEConstruction.failure(bytes: 0, scope: scope) { PEXSPICEBackannotationError.missingGeneratedSubcircuit }
    }

    private func trimmed(_ value: String) throws -> String {
        // Foundation's temporary workspace is opaque; the materialized String
        // payload is explicitly bounded by its input and admitted before the call.
        try PEXSPICEConstruction.string(bytes: value.utf8.count, scope: scope)
        try scope?.check(UInt64(value.utf8.count))
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try scope?.check(0)
        return result
    }

    private func sourceTokens(_ lines: [String]) throws -> [[String]] {
        try PEXSPICEConstruction.array([String].self, count: lines.count, scope: scope)
        var result: [[String]] = []; result.reserveCapacity(lines.count)
        for line in lines {
            try scope?.check()
            let value = try trimmed(line)
            if value.isEmpty || value.hasPrefix("*") || value.hasPrefix(";") { result.append([]) }
            else { result.append(try PEXSPICEConstruction.words(value, scope: scope)) }
        }
        return result
    }

    private func insertionIndexForInstance(in tokens: [[String]]) throws -> Int {
        if let topCell = options.topCell {
            let normalized = try trimmed(topCell)
            guard !normalized.isEmpty else { throw try PEXSPICEConstruction.failure(bytes: topCell.utf8.count, scope: scope) { PEXSPICEBackannotationError.topCellNotFound(topCell) } }
            try PEXSPICEConstruction.array(String.self, count: tokens.count, scope: scope)
            var stack: [String] = []; stack.reserveCapacity(tokens.count)
            for index in tokens.indices {
                try scope?.check()
                let row = tokens[index]
                guard let directive = row.first else { continue }
                if directive == ".subckt", row.count >= 2 { stack.append(row[1]) }
                else if directive == ".ends", let active = stack.popLast() {
                    try scope?.check(UInt64(try PEXParserStorageSize.add(active.utf8.count, normalized.utf8.count)))
                    let matches = active.caseInsensitiveCompare(normalized) == .orderedSame
                    try scope?.check(0)
                    if matches { return index }
                }
            }
            throw try PEXSPICEConstruction.failure(bytes: normalized.utf8.count, scope: scope) { PEXSPICEBackannotationError.topCellNotFound(normalized) }
        }
        return try endDirectiveIndex(in: tokens) ?? tokens.count
    }

    private func endDirectiveIndex(in tokens: [[String]]) throws -> Int? {
        for index in tokens.indices.reversed() { try scope?.check(); if tokens[index].first == ".end" { return index } }
        return nil
    }

    private func sourceNodeAliases(_ tokens: [[String]]) throws -> [String: String] {
        var maximum = 0
        for row in tokens { try scope?.check(); maximum = try PEXParserStorageSize.add(maximum, row.count) }
        try PEXSPICEConstruction.dictionary(String.self, String.self, count: maximum, scope: scope)
        var nodes: [String: String] = [:]; nodes.reserveCapacity(maximum)
        func add(_ value: String) throws {
            try scope?.check()
            nodes[try PEXSPICEConstruction.lower(value, scope: scope), default: value] = value
        }
        for row in tokens {
            try scope?.check()
            guard let first = row.first else { continue }
            let directive = try PEXSPICEConstruction.lower(first, scope: scope)
            if directive == ".subckt" || directive == ".global" {
                let begin = directive == ".subckt" ? 2 : 1
                if begin < row.count { for index in begin..<row.count { try add(row[index]) } }
                continue
            }
            guard !first.hasPrefix(".") else { continue }
            let firstEnd = first.index(after: first.startIndex)
            let character = try PEXSPICEConstruction.copy(first[first.startIndex..<firstEnd], scope: scope)
            let element = try PEXSPICEConstruction.upper(character, scope: scope)
            let end: Int
            switch element {
            case "R", "C", "L", "V", "I", "D", "B", "W", "F", "H": end = min(3, row.count)
            case "Q", "M", "E", "G": end = min(5, row.count)
            case "X": end = max(1, row.count - 1)
            default: end = row.count
            }
            if end > 1 {
                for index in 1..<end {
                    try scope?.check()
                    var hasEquals = false
                    for character in row[index] { try scope?.check(); if character == "=" { hasEquals = true; break } }
                    if !hasEquals { try add(row[index]) }
                }
            }
            // Preserve the legacy X-terminal pass, including its exact treatment
            // of parameter-looking terminal tokens.
            if element == "X", row.count > 2 { for index in 1..<(row.count - 1) { try add(row[index]) } }
        }
        return nodes
    }

    private func sourceElementIdentifiers(_ tokens: [[String]]) throws -> Set<String> {
        try PEXSPICEConstruction.set(String.self, count: tokens.count, scope: scope)
        var result: Set<String> = []; result.reserveCapacity(tokens.count)
        for row in tokens { try scope?.check(); if let first = row.first, !first.hasPrefix(".") { result.insert(first) } }
        return result
    }

    private func sourceSubcircuitNames(_ tokens: [[String]]) throws -> Set<String> {
        try PEXSPICEConstruction.set(String.self, count: tokens.count, scope: scope)
        var result: Set<String> = []; result.reserveCapacity(tokens.count)
        for row in tokens {
            try scope?.check()
            if row.count >= 2 {
                let directive = try PEXSPICEConstruction.lower(row[0], scope: scope)
                if directive == ".subckt" { result.insert(try PEXSPICEConstruction.lower(row[1], scope: scope)) }
            }
        }
        return result
    }

    private func resolveInstanceName(preferred: String, sourceIdentifiers: Set<String>) throws -> String {
        let sanitized = try PEXSPICEConstruction.sanitize(preferred, scope: scope)
        guard !sanitized.isEmpty else { throw try PEXSPICEConstruction.failure(bytes: preferred.utf8.count, scope: scope) { PEXSPICEBackannotationError.instanceNameCollision(preferred) } }
        var candidate = sanitized, suffix = 2
        while sourceIdentifiers.contains(candidate) {
            try scope?.check()
            candidate = try PEXSPICEConstruction.text(sanitized, "_", try PEXSPICEConstruction.integer(suffix, scope: scope), scope: scope)
            suffix = try PEXParserStorageSize.add(suffix, 1)
        }
        return candidate
    }
}
