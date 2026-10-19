import Foundation
import PEXCore
import PEXPersistence

/// Checks exact parsed source identities and required root terminals, not leaf aliases.
public struct PEXSourceConnectivityChecker: Sendable {
    public init() {}

    private struct Index {
        private struct Identity: Hashable { let path: [String]; let node: String }
        var nodes: Set<String> = []
        var required: Set<String> = []
        var diagnostics: [String] = []
        private var identities: Set<Identity> = []
        private var encodings: [String: Identity] = [:]
        var sourceNodeCount: Int { identities.count }
        private var remainingRecords = 1_000_000
        private var remainingIdentifierBytes = 256 * 1024 * 1024
        private(set) var exhausted = false

        mutating func admit(_ node: String, path: [String]) {
            guard !exhausted else { return }
            var bytes = node.utf8.count
            for step in path {
                let (sum, overflow) = bytes.addingReportingOverflow(step.utf8.count + 1)
                guard !overflow else { exhaust(); return }
                bytes = sum
            }
            let (encodedBytes, overflow) = bytes.multipliedReportingOverflow(by: path.isEmpty ? 1 : 2)
            guard !overflow, remainingRecords > 0, encodedBytes <= remainingIdentifierBytes else { exhaust(); return }
            remainingRecords -= 1; remainingIdentifierBytes -= encodedBytes
            let identity = Identity(path: path, node: node)
            identities.insert(identity)
            let names = path.isEmpty ? [node] : [(path + [node]).joined(separator: ":"), (path + [node]).joined(separator: "/")]
            for name in names {
                if let previous = encodings[name], previous != identity {
                    diagnostics.append("Distinct source occurrences have an ambiguous terminal encoding")
                }
                encodings[name] = identity; nodes.insert(name)
            }
        }
        private mutating func exhaust() {
            exhausted = true
            diagnostics.append("Source identity record/byte admission ceiling exceeded")
        }
    }
    private struct SpiceCell {
        var ports: [String] = []
        var lines: [[String]] = []
    }

    public func check(sourceNetlistURL: URL, sourceNetlistFormat: NetlistFormat,
                      ir: ParasiticIR, topCell: String? = nil) throws -> PEXSourceConnectivityReport {
        let pins = ir.nets.flatMap(\.nodes).filter { $0.kind == .pin }
        guard [.spice, .cdl, .verilog].contains(sourceNetlistFormat) else {
            return report(status: .warning, format: sourceNetlistFormat, pins: pins.count,
                diagnostics: ["Source terminal checking is unsupported for this format"])
        }
        let bytes = try PEXBoundedInputReader().read(sourceNetlistURL)
        guard let source = String(data: bytes, encoding: .utf8) else {
            throw PEXError.parseFailed(cornerID: ir.cornerID, message: "Source netlist is not UTF-8")
        }
        if Task.isCancelled { throw PEXError(kind: .cancelled, stage: .irValidation, message: "Source inspection cancelled") }
        let spice = sourceNetlistFormat != .verilog
        let index = spice ? spiceIndex(source, topCell: topCell) : verilogIndex(source, topCell: topCell)
        if Task.isCancelled { throw PEXError(kind: .cancelled, stage: .irValidation, message: "Source inspection cancelled") }
        func normalized(_ value: String) -> String { spice ? value.lowercased() : value }
        func candidates(_ pin: ParasiticNode) -> Set<String> {
            let name = normalized(pin.name.value)
            guard let path = pin.instancePath?.value, !path.isEmpty else { return [name] }
            let owner = normalized(path)
            if name.hasPrefix(owner + ":") || name.hasPrefix(owner + "/") { return [name] }
            return [owner + ":" + name, owner + "/" + name]
        }
        let unmatched = pins.filter { candidates($0).isDisjoint(with: index.nodes) }.map { $0.name.value }
        let rootPins = Set(pins.filter { $0.instancePath?.value.isEmpty ?? true }.map { normalized($0.name.value) })
        let missing = index.required.subtracting(rootPins).sorted()
        var diagnostics = index.diagnostics
        if !unmatched.isEmpty { diagnostics.append("Exact source occurrence/terminal is absent for \(unmatched.count) extracted pin(s)") }
        if !missing.isEmpty { diagnostics.append("Required root terminals are missing: \(missing.joined(separator: ", "))") }
        if pins.isEmpty { diagnostics.append("Canonical ParasiticIR contains no pin nodes; source connectivity is unproven") }
        let contradicted = !missing.isEmpty || (!unmatched.isEmpty && (!index.nodes.isEmpty || index.diagnostics.isEmpty))
        let status: PEXSourceConnectivityStatus = contradicted ? .failed
            : diagnostics.isEmpty && !pins.isEmpty ? .passed : .warning
        return .init(status: status, sourceNetlistFormat: sourceNetlistFormat,
            sourceNodeCount: index.sourceNodeCount, extractedPinNodeCount: pins.count,
            matchedPinNodeCount: pins.count - unmatched.count, unmatchedExtractedPinNodes: unmatched,
            sourceOnlyNodes: missing, diagnostics: diagnostics)
    }

    private func report(status: PEXSourceConnectivityStatus, format: NetlistFormat, pins: Int,
                        diagnostics: [String]) -> PEXSourceConnectivityReport {
        .init(status: status, sourceNetlistFormat: format, sourceNodeCount: 0,
            extractedPinNodeCount: pins, matchedPinNodeCount: 0, diagnostics: diagnostics)
    }

    private func spiceIndex(_ source: String, topCell: String?) -> Index {
        var result = Index(), cells: [String: SpiceCell] = [:], flat: [[String]] = []
        var current: String?, logical: [String] = []
        for raw in source.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("+"), !logical.isEmpty { logical[logical.count - 1] += " " + line.dropFirst() }
            else { logical.append(line) }
        }
        for line in logical {
            guard !line.isEmpty, !line.hasPrefix("*") else { continue }
            let tokens = line.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
            guard let first = tokens.first else { continue }
            if first == ".subckt" {
                guard tokens.count >= 2, current == nil, cells[tokens[1]] == nil else {
                    result.diagnostics.append("Duplicate or malformed SPICE subcircuit boundary"); continue
                }
                current = tokens[1]
                cells[tokens[1]] = SpiceCell(ports: Array(tokens.dropFirst(2).prefix { !$0.contains("=") && $0 != "params:" }))
            } else if first == ".ends" {
                if current == nil || (tokens.count > 1 && tokens[1] != current) { result.diagnostics.append("Mismatched SPICE subcircuit end") }
                current = nil
            } else if !first.hasPrefix(".") {
                if let current { cells[current]!.lines.append(tokens) } else { flat.append(tokens) }
            }
        }
        if current != nil { result.diagnostics.append("Unterminated SPICE subcircuit") }
        func actuals(_ tokens: [String]) -> [String] {
            guard let kind = tokens.first?.first else { return [] }
            let count: Int
            switch kind {
            case "r", "c", "l", "v", "i", "d", "b": count = 2
            case "q", "j": count = 3
            case "m", "e", "g", "s": count = 4
            case "f", "h", "w": count = 2
            case "x": return Array(tokens.dropFirst().prefix { !$0.contains("=") && $0 != "params:" }.dropLast())
            default: count = min(2, max(0, tokens.count - 1))
            }
            return Array(tokens.dropFirst().prefix(count))
        }
        if cells.isEmpty {
            if topCell != nil { result.diagnostics.append("Flat SPICE deck has no declared root terminal boundary") }
            for tokens in flat { for node in actuals(tokens) where node != "0" { result.admit(node, path: []) } }
            return result
        }
        let referenced = Set(cells.values.flatMap(\.lines).filter { $0.first?.hasPrefix("x") == true }
            .compactMap { $0.prefix { !$0.contains("=") && $0 != "params:" }.last })
        let roots = Set(cells.keys).subtracting(referenced)
        let selected = topCell?.lowercased() ?? (roots.count == 1 ? roots.first : nil)
        guard let selected, let root = cells[selected] else {
            result.diagnostics.append("Requested SPICE root is missing or ambiguous"); return result
        }
        if Set(root.ports).count != root.ports.count { result.diagnostics.append("Duplicate SPICE root terminal") }
        result.required = Set(root.ports.filter { $0 != "0" })
        var remaining = 1_000_000
        func visit(_ name: String, path: [String], ancestors: Set<String>) {
            guard remaining > 0, path.count <= 1024 else { result.diagnostics.append("SPICE source occurrence ceiling exceeded"); return }
            remaining -= 1
            guard !ancestors.contains(name), let cell = cells[name] else {
                result.diagnostics.append("Recursive SPICE source occurrence cannot be proven"); return
            }
            func admit(_ node: String) {
                guard node != "0" else { return }
                result.admit(node, path: path)
            }
            for port in cell.ports { admit(port) }
            var instanceNames = Set<String>()
            for tokens in cell.lines {
                if result.exhausted { return }
                if Task.isCancelled { result.diagnostics.append("SPICE source inspection cancelled"); return }
                for node in actuals(tokens) { admit(node) }
                guard let instance = tokens.first else { continue }
                guard instanceNames.insert(instance).inserted else { result.diagnostics.append("Duplicate SPICE instance identity"); continue }
                if instance.hasPrefix("x"), let child = tokens.prefix(while: { !$0.contains("=") && $0 != "params:" }).last,
                   let childCell = cells[child] {
                    guard actuals(tokens).count == childCell.ports.count else {
                        result.diagnostics.append("SPICE instance terminal count mismatch"); continue
                    }
                    visit(child, path: path + [instance], ancestors: ancestors.union([name]))
                }
            }
        }
        visit(selected, path: [], ancestors: [])
        return result
    }

    private func verilogIndex(_ source: String, topCell: String?) -> Index {
        let parser = PEXVerilogConnectivityParser()
        let tokenization = parser.tokenize(parser.stripComments(source), maximumTokens: 1_000_000)
        guard tokenization.complete else { return Index(diagnostics: ["Verilog source token ceiling exceeded"]) }
        let tokens = tokenization.tokens
        func identifier(_ token: String) -> String { token.hasPrefix("\\") ? String(token.dropFirst()) : token }
        struct Module { let ports: [String]; let body: [String] }
        var modules: [String: Module] = [:], result = Index(), cursor = 0
        func group(_ index: inout Int) -> [String] {
            guard index < tokens.count, tokens[index] == "(" else { return [] }
            index += 1; var depth = 1, values: [String] = []
            while index < tokens.count, depth > 0 {
                let token = tokens[index]; index += 1
                if token == "(" { depth += 1 } else if token == ")" { depth -= 1 }
                if depth > 0 { values.append(token) }
            }
            if depth != 0 { result.diagnostics.append("Unterminated Verilog terminal list") }
            return values
        }
        func ports(_ values: [String]) -> [String] {
            var names: [String] = [], segment: [String] = [], bracketDepth = 0
            for token in values + [","] {
                if token == "[" { bracketDepth += 1 }
                else if token == "]" { bracketDepth -= 1 }
                else if token == ",", bracketDepth == 0 {
                    if let name = segment.last(where: { parser.isConnectivityIdentifier($0) }) { names.append(identifier(name)) }
                    segment = []
                } else if bracketDepth == 0 { segment.append(token) }
            }
            return names
        }
        while cursor < tokens.count {
            guard tokens[cursor] == "module" else { cursor += 1; continue }
            cursor += 1
            if cursor < tokens.count, ["automatic", "static"].contains(tokens[cursor]) { cursor += 1 }
            guard cursor < tokens.count else { break }
            let name = identifier(tokens[cursor]); cursor += 1
            if cursor < tokens.count, tokens[cursor] == "#" { cursor += 1; _ = group(&cursor) }
            guard cursor < tokens.count, tokens[cursor] == "(" else { result.diagnostics.append("Verilog module has no terminal boundary"); break }
            let rootPorts = ports(group(&cursor)), start = cursor
            while cursor < tokens.count, tokens[cursor] != "endmodule" { cursor += 1 }
            guard cursor < tokens.count else { result.diagnostics.append("Verilog module boundary is incomplete"); break }
            let body = Array(tokens[start..<cursor]); cursor += 1
            guard modules.updateValue(Module(ports: rootPorts, body: body), forKey: name) == nil else {
                result.diagnostics.append("Duplicate Verilog module"); continue
            }
        }
        let selected = topCell ?? (modules.count == 1 ? modules.keys.first : nil)
        guard let selected, let root = modules[selected] else { result.diagnostics.append("Requested Verilog module boundary is missing or ambiguous"); return result }
        if Set(root.ports).count != root.ports.count { result.diagnostics.append("Duplicate Verilog root terminal") }
        result.required = Set(root.ports)
        var remaining = 1_000_000
        func visit(_ name: String, path: [String], ancestors: Set<String>) {
            guard remaining > 0, path.count <= 1024, !ancestors.contains(name), let module = modules[name] else {
                result.diagnostics.append("Verilog source occurrence is recursive or exceeds its ceiling"); return
            }
            remaining -= 1
            func admit(_ node: String) {
                result.admit(node, path: path)
            }
            module.ports.forEach(admit)
            var statement: [String] = [], seen = Set<String>()
            for token in module.body {
                if result.exhausted { return }
                if Task.isCancelled { result.diagnostics.append("Verilog source inspection cancelled"); return }
                guard token == ";" else { statement.append(token); continue }
                defer { statement = [] }
                var connectionOpen = statement.firstIndex(of: "(")
                if let parameterOpen = connectionOpen, parameterOpen > 0, statement[parameterOpen - 1] == "#" {
                    var depth = 1, end = parameterOpen + 1
                    while end < statement.count, depth > 0 {
                        if statement[end] == "(" { depth += 1 } else if statement[end] == ")" { depth -= 1 }
                        end += 1
                    }
                    connectionOpen = depth == 0 ? statement[end...].firstIndex(of: "(") : nil
                }
                guard let open = connectionOpen, open >= 2 else {
                    if let first = statement.first, ["input", "output", "inout", "wire", "tri", "logic", "reg", "assign"].contains(first) {
                        for node in statement.dropFirst() where parser.isConnectivityIdentifier(node) { admit(identifier(node)) }
                    }
                    continue
                }
                let instance = identifier(statement[open - 1]), cell = identifier(statement[0])
                guard parser.isConnectivityIdentifier(statement[open - 1]), seen.insert(instance).inserted else {
                    result.diagnostics.append("Ambiguous Verilog instance identity"); continue
                }
                var named: [String] = [], actuals: [String] = [], i = open + 1
                while i < statement.count {
                    if i + 2 < statement.count, statement[i] == ".", statement[i + 2] == "(" {
                        named.append(identifier(statement[i + 1])); i += 3
                        var depth = 1
                        while i < statement.count, depth > 0 {
                            if statement[i] == "(" { depth += 1 }
                            else if statement[i] == ")" { depth -= 1 }
                            else if parser.isConnectivityIdentifier(statement[i]) { actuals.append(identifier(statement[i])) }
                            i += 1
                        }
                        if depth != 0 { result.diagnostics.append("Incomplete Verilog named connection") }
                    } else {
                        if parser.isConnectivityIdentifier(statement[i]) { actuals.append(identifier(statement[i])) }
                        i += 1
                    }
                }
                if !named.isEmpty {
                    guard Set(named).count == named.count else { result.diagnostics.append("Duplicate Verilog named terminal"); continue }
                    if let declared = modules[cell], !Set(named).isSubset(of: Set(declared.ports)) {
                        result.diagnostics.append("Verilog instance names an undeclared terminal"); continue
                    }
                    for port in named {
                        result.admit(port, path: path + [instance])
                    }
                }
                if modules[cell] != nil { visit(cell, path: path + [instance], ancestors: ancestors.union([name])) }
                actuals.forEach(admit)
            }
        }
        visit(selected, path: [], ancestors: [])
        return result
    }
}
