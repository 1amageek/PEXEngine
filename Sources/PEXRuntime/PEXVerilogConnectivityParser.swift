import Foundation

/// Extracts module ports, declarations, and connection identifiers from
/// Verilog/SystemVerilog netlists without attempting to elaborate RTL.
public struct PEXVerilogConnectivityParser: Sendable {
    public init() {}

    public func parse(_ source: String) -> PEXVerilogConnectivityParserResult {
        let tokens = tokenize(stripComments(source))
        var sourceNodes: Set<String> = []
        var moduleNames: Set<String> = []
        var parsedPortCount = 0
        var parsedInstanceCount = 0
        var diagnostics: [String] = []
        var index = 0

        while index < tokens.count {
            guard tokens[index] == "module" else {
                index += 1
                continue
            }
            let moduleStart = index
            index += 1
            guard let moduleName = nextIdentifier(in: tokens, from: &index) else {
                diagnostics.append("Verilog module declaration is missing a name")
                continue
            }
            moduleNames.insert(moduleName)

            if index < tokens.count, tokens[index] == "#" {
                skipBalancedParentheses(in: tokens, from: &index)
            }

            if index < tokens.count, tokens[index] == "(" {
                let ports = collectIdentifiersUntilClosingParenthesis(in: tokens, from: &index)
                parsedPortCount += ports.count
                sourceNodes.formUnion(ports)
            } else {
                diagnostics.append("Verilog module '\(moduleName)' has no port list")
            }

            var bodyIdentifiers: Set<String> = []
            var bodyInstanceCount = 0
            var sawEndmodule = false
            while index < tokens.count {
                if tokens[index] == "endmodule" {
                    sawEndmodule = true
                    index += 1
                    break
                }
                if tokens[index] == "module" {
                    diagnostics.append("Nested Verilog module declaration near token \(moduleStart)")
                    break
                }
                if tokens[index] == "(" {
                    let connections = collectIdentifiersUntilClosingParenthesis(in: tokens, from: &index)
                    bodyIdentifiers.formUnion(connections)
                    bodyInstanceCount += 1
                    continue
                }
                let token = tokens[index]
                if isConnectivityIdentifier(token) {
                    bodyIdentifiers.insert(token)
                }
                index += 1
            }
            sourceNodes.formUnion(bodyIdentifiers)
            parsedInstanceCount += bodyInstanceCount
            if !sawEndmodule {
                diagnostics.append("Verilog module '\(moduleName)' is missing endmodule")
                break
            }
        }

        if moduleNames.isEmpty {
            diagnostics.append("No Verilog module declaration was found")
        }
        return PEXVerilogConnectivityParserResult(
            sourceNodes: Array(sourceNodes),
            moduleNames: Array(moduleNames),
            parsedPortCount: parsedPortCount,
            parsedInstanceCount: parsedInstanceCount,
            diagnostics: diagnostics
        )
    }

    private func collectIdentifiersUntilClosingParenthesis(
        in tokens: [String],
        from index: inout Int
    ) -> Set<String> {
        var identifiers: Set<String> = []
        guard index < tokens.count, tokens[index] == "(" else { return identifiers }
        index += 1
        var depth = 1
        while index < tokens.count, depth > 0 {
            let token = tokens[index]
            if token == "(" {
                depth += 1
            } else if token == ")" {
                depth -= 1
            } else if depth > 0, isConnectivityIdentifier(token) {
                identifiers.insert(token)
            }
            index += 1
        }
        return identifiers
    }

    private func skipBalancedParentheses(in tokens: [String], from index: inout Int) {
        guard index < tokens.count, tokens[index] == "#" else { return }
        index += 1
        guard index < tokens.count, tokens[index] == "(" else { return }
        _ = collectIdentifiersUntilClosingParenthesis(in: tokens, from: &index)
    }

    private func nextIdentifier(in tokens: [String], from index: inout Int) -> String? {
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if isConnectivityIdentifier(token) {
                return token
            }
            if token == ";" || token == "endmodule" {
                return nil
            }
        }
        return nil
    }

    private func isConnectivityIdentifier(_ token: String) -> Bool {
        guard !token.isEmpty,
              token.first?.isLetter == true || token.first == "_" || token.first == "$" else {
            return false
        }
        let keywords: Set<String> = [
            "module", "endmodule", "input", "output", "inout", "wire", "tri", "wand", "wor",
            "logic", "reg", "integer", "time", "signed", "unsigned", "parameter", "localparam",
            "genvar", "generate", "endgenerate", "assign", "always", "always_ff", "always_comb",
            "always_latch", "begin", "end", "if", "else", "case", "endcase", "for", "while",
            "repeat", "function", "endfunction", "task", "endtask", "specify", "endspecify",
            "primitive", "endprimitive", "table", "endtable", "or", "and", "not", "buf", "xnor",
            "xor", "nand", "nor", "nmos", "pmos", "tran", "tranif0", "tranif1", "supply0",
            "supply1", "highz0", "highz1", "strong0", "strong1", "pull0", "pull1", "small0",
            "small1", "medium0", "medium1", "large0", "large1", "event", "typedef", "struct",
            "enum", "interface", "endinterface", "package", "endpackage", "import", "export",
            "automatic", "static", "default_nettype", "include", "define",
        ]
        return !keywords.contains(token.lowercased())
    }

    private func stripComments(_ source: String) -> String {
        var result = String()
        var index = source.startIndex
        var inLineComment = false
        var inBlockComment = false
        while index < source.endIndex {
            let next = source.index(after: index)
            let character = source[index]
            let nextCharacter = next < source.endIndex ? source[next] : "\0"
            if inLineComment {
                if character.isNewline {
                    inLineComment = false
                    result.append(character)
                }
            } else if inBlockComment {
                if character == "*", nextCharacter == "/" {
                    inBlockComment = false
                    index = next
                } else if character.isNewline {
                    result.append(character)
                }
            } else if character == "/", nextCharacter == "/" {
                inLineComment = true
                index = next
            } else if character == "/", nextCharacter == "*" {
                inBlockComment = true
                index = next
            } else {
                result.append(character)
            }
            index = source.index(after: index)
        }
        return result
    }

    private func tokenize(_ source: String) -> [String] {
        var tokens: [String] = []
        var current = String()
        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(current)
            current.removeAll(keepingCapacity: true)
        }
        for character in source {
            if character.isLetter || character.isNumber || character == "_" || character == "$" || character == "\\" {
                current.append(character)
            } else {
                flush()
                if "()[]{};,:.#@".contains(character) {
                    tokens.append(String(character))
                }
            }
        }
        flush()
        return tokens.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\\")) }
            .filter { !$0.isEmpty }
    }
}
