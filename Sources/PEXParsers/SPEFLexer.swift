public struct SPEFLexer: Sendable {
    private let source: String
    private let fileName: String?
    private var characters: [Character]
    private var position: Int
    private var line: Int
    private var column: Int

    public init(source: String, fileName: String? = nil) {
        self.source = source
        self.fileName = fileName
        self.characters = Array(source)
        self.position = 0
        self.line = 1
        self.column = 1
    }

    public mutating func tokenize() -> [SPEFToken.Located] {
        var tokens: [SPEFToken.Located] = []
        while position < characters.count {
            skipWhitespaceExceptNewline()
            guard position < characters.count else { break }

            let ch = characters[position]
            let loc = currentLocation()

            if ch == "\n" {
                tokens.append(SPEFToken.Located(token: .newline, location: loc))
                advance()
                continue
            }

            // Comment: // to end of line
            if ch == "/" && peek(1) == "/" {
                skipToEndOfLine()
                continue
            }

            // Asterisk: keyword or mapped name
            if ch == "*" {
                advance() // consume *
                if position < characters.count && characters[position].isNumber {
                    // Mapped name: *123
                    let numStr = consumeWhile { $0.isNumber }
                    if let num = Int(numStr) {
                        tokens.append(SPEFToken.Located(token: .mappedName(num), location: loc))
                    }
                } else {
                    // Keyword: *SPEF, *DESIGN, etc.
                    let name = consumeWhile { $0.isLetter || $0 == "_" }
                    tokens.append(SPEFToken.Located(token: .keyword(name), location: loc))
                }
                continue
            }

            // Quoted string
            if ch == "\"" {
                advance() // consume opening "
                let content = consumeWhile { $0 != "\"" && $0 != "\n" }
                if position < characters.count && characters[position] == "\"" {
                    advance() // consume closing "
                }
                tokens.append(SPEFToken.Located(token: .string(content), location: loc))
                continue
            }

            // Number (including negative and decimal)
            if ch.isNumber || (ch == "-" && position + 1 < characters.count && characters[position + 1].isNumber) || (ch == "+" && position + 1 < characters.count && characters[position + 1].isNumber) {
                let numStr = consumeNumber()
                if let value = Double(numStr) {
                    tokens.append(SPEFToken.Located(token: .number(value), location: loc))
                } else {
                    // Fallback to identifier
                    tokens.append(SPEFToken.Located(token: .identifier(numStr), location: loc))
                }
                continue
            }

            // Punctuation
            if ch == ":" {
                tokens.append(SPEFToken.Located(token: .colon, location: loc))
                advance()
                continue
            }
            if ch == "/" {
                tokens.append(SPEFToken.Located(token: .slash, location: loc))
                advance()
                continue
            }
            if ch == "[" {
                tokens.append(SPEFToken.Located(token: .leftBracket, location: loc))
                advance()
                continue
            }
            if ch == "]" {
                tokens.append(SPEFToken.Located(token: .rightBracket, location: loc))
                advance()
                continue
            }

            // Identifier (everything else that's not whitespace)
            if ch.isLetter || ch == "_" || ch == "\\" {
                let name = consumeWhile { c in
                    c.isLetter || c.isNumber || c == "_" || c == "." || c == "\\" || c == "[" || c == "]" || c == "/" || c == ":"
                }
                tokens.append(SPEFToken.Located(token: .identifier(name), location: loc))
                continue
            }

            // Unknown character - skip
            advance()
        }

        tokens.append(SPEFToken.Located(token: .endOfFile, location: currentLocation()))
        return tokens
    }

    // MARK: - Helper methods

    private func currentLocation() -> SPEFSourceLocation {
        SPEFSourceLocation(file: fileName, line: line, column: column)
    }

    private func peek(_ offset: Int) -> Character? {
        let idx = position + offset
        guard idx < characters.count else { return nil }
        return characters[idx]
    }

    private mutating func advance() {
        if position < characters.count {
            if characters[position] == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
            position += 1
        }
    }

    private mutating func skipWhitespaceExceptNewline() {
        while position < characters.count {
            let ch = characters[position]
            if ch == " " || ch == "\t" || ch == "\r" {
                advance()
            } else {
                break
            }
        }
    }

    private mutating func skipToEndOfLine() {
        while position < characters.count && characters[position] != "\n" {
            advance()
        }
    }

    private mutating func consumeWhile(_ predicate: (Character) -> Bool) -> String {
        var result = ""
        while position < characters.count && predicate(characters[position]) {
            result.append(characters[position])
            advance()
        }
        return result
    }

    private mutating func consumeNumber() -> String {
        var result = ""
        // Optional sign
        if position < characters.count && (characters[position] == "-" || characters[position] == "+") {
            result.append(characters[position])
            advance()
        }
        // Integer part
        while position < characters.count && characters[position].isNumber {
            result.append(characters[position])
            advance()
        }
        // Decimal part
        if position < characters.count && characters[position] == "." {
            result.append(characters[position])
            advance()
            while position < characters.count && characters[position].isNumber {
                result.append(characters[position])
                advance()
            }
        }
        // Exponent part
        if position < characters.count && (characters[position] == "e" || characters[position] == "E") {
            result.append(characters[position])
            advance()
            if position < characters.count && (characters[position] == "+" || characters[position] == "-") {
                result.append(characters[position])
                advance()
            }
            while position < characters.count && characters[position].isNumber {
                result.append(characters[position])
                advance()
            }
        }
        return result
    }
}
