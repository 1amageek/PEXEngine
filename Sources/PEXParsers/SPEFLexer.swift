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

    /// The retention anchor must outlive all shared copies of the returned tokens.
    public static func tokenize(
        source: String, fileName: String? = nil,
        control: any PEXParserResourceControlling
    ) throws -> (value: [SPEFToken.Located], retention: PEXParserRetention) {
        var characterCount = 0
        var byteCount = 0
        for _ in source {
            try control.checkpoint(workUnits: 1)
            characterCount = try PEXParserStorageSize.add(characterCount, 1)
        }
        for _ in source.utf8 {
            try control.checkpoint(workUnits: 1)
            byteCount = try PEXParserStorageSize.add(byteCount, 1)
        }
        let diagnosticPrefix = "Invalid character ''".utf8.count
        // Character backing plus old/new scanner or invalid-character text.
        let temporary = try PEXParserStorageSize.add(
            PEXParserStorageSize.array(Character.self, count: characterCount),
            PEXParserStorageSize.add(PEXParserStorageSize.multiply(byteCount, 3),
                PEXParserStorageSize.multiply(diagnosticPrefix, 2)))
        let scope = try PEXParserResourceScope(control: control, temporary: UInt64(temporary))
        try scope.check(0)
        let characters = Array(source)
        try scope.check(0)
        var lexer = Self(source: source, fileName: fileName, characters: characters,
            position: 0, line: 1, column: 1)
        var tokenCount = 0
        var tokenText = 0
        try lexer.scan(checkpoint: { try scope.check() }) { token in
            try scope.check()
            tokenCount = try PEXParserStorageSize.add(tokenCount, 1)
            switch token.token {
            case .keyword(let text), .identifier(let text), .string(let text), .invalid(let text):
                tokenText = try PEXParserStorageSize.add(tokenText, text.utf8.count)
            default: break
            }
        }
        let retained = try PEXParserStorageSize.add(
            PEXParserStorageSize.array(SPEFToken.Located.self, count: tokenCount),
            PEXParserStorageSize.multiply(tokenText, 2))
        try scope.reserve(kind: .retained, byteCount: UInt64(retained))
        try scope.check(0)
        var tokens: [SPEFToken.Located] = []
        tokens.reserveCapacity(tokenCount)
        lexer.position = 0; lexer.line = 1; lexer.column = 1
        try lexer.scan(checkpoint: { try scope.check() }) { token in
            try scope.check()
            tokens.append(token)
        }
        try scope.check(0)
        guard tokens.count == tokenCount else { throw PEXParserResourceError.capacityOverflow }
        return (tokens, scope.retention)
    }

    private init(source: String, fileName: String?, characters: [Character],
                 position: Int, line: Int, column: Int) {
        self.source = source
        self.fileName = fileName
        self.characters = characters
        self.position = position
        self.line = line
        self.column = column
    }

    public mutating func tokenize() -> [SPEFToken.Located] {
        var tokens: [SPEFToken.Located] = []
        scan(checkpoint: {}) { tokens.append($0) }
        return tokens
    }

    private mutating func scan(checkpoint: () throws -> Void,
        _ emit: (SPEFToken.Located) throws -> Void) rethrows {
        while position < characters.count {
            try checkpoint()
            try skipWhitespaceExceptNewline(checkpoint: checkpoint)
            guard position < characters.count else { break }

            let ch = characters[position]
            let loc = currentLocation()

            if ch == "\n" {
                try emit(SPEFToken.Located(token: .newline, location: loc))
                advance()
                continue
            }

            // Comment: // to end of line
            if ch == "/" && peek(1) == "/" {
                try skipToEndOfLine(checkpoint: checkpoint)
                continue
            }

            // Asterisk: keyword or mapped name
            if ch == "*" {
                advance() // consume *
                if position < characters.count && characters[position].isNumber {
                    // Mapped name: *123
                    let numStr = try consumeWhile(checkpoint: checkpoint) { $0.isNumber }
                    if let num = Int(numStr) {
                        try emit(SPEFToken.Located(token: .mappedName(num), location: loc))
                    }
                } else {
                    // Keyword: *SPEF, *DESIGN, etc.
                    let name = try consumeWhile(checkpoint: checkpoint) { $0.isLetter || $0 == "_" }
                    try emit(SPEFToken.Located(token: .keyword(name), location: loc))
                }
                continue
            }

            // Quoted string
            if ch == "\"" {
                advance() // consume opening "
                let content = try consumeWhile(checkpoint: checkpoint) { $0 != "\"" && $0 != "\n" }
                if position < characters.count && characters[position] == "\"" {
                    advance() // consume closing "
                } else {
                    try emit(SPEFToken.Located(token: .invalid("Unterminated string literal"), location: loc))
                    continue
                }
                try emit(SPEFToken.Located(token: .string(content), location: loc))
                continue
            }

            // Number (including negative and decimal)
            if ch.isNumber || (ch == "-" && position + 1 < characters.count && characters[position + 1].isNumber) || (ch == "+" && position + 1 < characters.count && characters[position + 1].isNumber) {
                let numStr = try consumeNumber(checkpoint: checkpoint)
                if let value = Double(numStr) {
                    try emit(SPEFToken.Located(token: .number(value), location: loc))
                } else {
                    // Fallback to identifier
                    try emit(SPEFToken.Located(token: .identifier(numStr), location: loc))
                }
                continue
            }

            // Punctuation
            if ch == ":" {
                try emit(SPEFToken.Located(token: .colon, location: loc))
                advance()
                continue
            }
            if ch == "/" {
                try emit(SPEFToken.Located(token: .slash, location: loc))
                advance()
                continue
            }
            if ch == "[" {
                try emit(SPEFToken.Located(token: .leftBracket, location: loc))
                advance()
                continue
            }
            if ch == "]" {
                try emit(SPEFToken.Located(token: .rightBracket, location: loc))
                advance()
                continue
            }

            // Identifier (everything else that's not whitespace)
            if ch.isLetter || ch == "_" || ch == "\\" || ch == "$" || ch == "#" {
                let name = try consumeIdentifier(checkpoint: checkpoint)
                try emit(SPEFToken.Located(token: .identifier(name), location: loc))
                continue
            }

            try emit(SPEFToken.Located(token: .invalid("Invalid character '\(ch)'"), location: loc))
            advance()
        }

        try checkpoint()
        try emit(SPEFToken.Located(token: .endOfFile, location: currentLocation()))
    }

    // MARK: - Helper methods

    private mutating func consumeIdentifier(checkpoint: () throws -> Void) rethrows -> String {
        var name = ""
        while position < characters.count {
            try checkpoint()
            let character = characters[position]
            if character == "\\" && peek(1) == "-" {
                name.append("-")
                advance()
                advance()
            } else if character == "-", let next = peek(1), next.isNumber {
                // SPEF identifiers may contain signed integer suffixes.
                name.append(character)
                advance()
            } else if character.isLetter || character.isNumber || character == "_"
                || character == "." || character == "\\" || character == "["
                || character == "]" || character == "/" || character == ":"
                || character == "$" || character == "#" {
                name.append(character)
                advance()
            } else {
                break
            }
        }
        return name
    }

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

    private mutating func skipWhitespaceExceptNewline(checkpoint: () throws -> Void) rethrows {
        while position < characters.count {
            try checkpoint()
            let ch = characters[position]
            if ch == " " || ch == "\t" || ch == "\r" {
                advance()
            } else {
                break
            }
        }
    }

    private mutating func skipToEndOfLine(checkpoint: () throws -> Void) rethrows {
        while position < characters.count && characters[position] != "\n" {
            try checkpoint()
            advance()
        }
    }

    private mutating func consumeWhile(checkpoint: () throws -> Void, _ predicate: (Character) -> Bool) rethrows -> String {
        var result = ""
        while position < characters.count && predicate(characters[position]) {
            try checkpoint()
            result.append(characters[position])
            advance()
        }
        return result
    }

    private mutating func consumeNumber(checkpoint: () throws -> Void) rethrows -> String {
        var result = ""
        // Optional sign
        if position < characters.count && (characters[position] == "-" || characters[position] == "+") {
            result.append(characters[position])
            advance()
        }
        // Integer part
        while position < characters.count && characters[position].isNumber {
            try checkpoint()
            result.append(characters[position])
            advance()
        }
        // Decimal part
        if position < characters.count && characters[position] == "." {
            result.append(characters[position])
            advance()
            while position < characters.count && characters[position].isNumber {
                try checkpoint()
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
                try checkpoint()
                result.append(characters[position])
                advance()
            }
        }
        return result
    }
}
