import PEXCore

// MARK: - SPEF Parse Tree Types

public struct SPEFParseTree: Sendable {
    public let header: SPEFHeader
    public let nameMap: [Int: String]
    public let ports: [SPEFPort]
    public let nets: [SPEFNetBlock]
}

public struct SPEFHeader: Sendable {
    public let spefVersion: String
    public let designName: String
    public let date: String?
    public let vendor: String?
    public let program: String?
    public let divider: String
    public let delimiter: String
    public let busDelimiterOpen: String
    public let busDelimiterClose: String
    public let timeUnit: String
    public let timeScaleFactor: Double
    public let capUnit: String
    public let capScaleFactor: Double
    public let resUnit: String
    public let resScaleFactor: Double
    public let inductUnit: String?
    public let inductScaleFactor: Double?
}

public struct SPEFPort: Sendable {
    public let name: String
    public let direction: SPEFDirection
    public let coordinate: Point2D?
}

public enum SPEFDirection: String, Sendable {
    case input = "I"
    case output = "O"
    case bidirectional = "B"
}

public struct SPEFNetBlock: Sendable {
    public let netName: String
    public let totalCap: Double
    public let connections: [SPEFConnection]
    public let capacitors: [SPEFCapacitor]
    public let resistors: [SPEFResistor]
}

public struct SPEFConnection: Sendable {
    public let type: SPEFConnType
    public let name: String
    public let direction: SPEFDirection
    public let coordinate: Point2D?
}

public enum SPEFConnType: String, Sendable {
    case port = "P"
    case instancePin = "I"
}

public struct SPEFCapacitor: Sendable {
    public let id: Int
    public let nodeA: String
    public let nodeB: String?
    public let value: Double
}

public struct SPEFResistor: Sendable {
    public let id: Int
    public let nodeA: String
    public let nodeB: String
    public let value: Double
}

// MARK: - SPEF Parser

public struct SPEFParser: Sendable {
    public init() {}

    public func parse(tokens: [SPEFToken.Located]) throws -> SPEFParseTree {
        try rejectInvalidTokens(tokens)
        var cursor = TokenCursor(tokens: tokens)

        let header = try parseHeader(&cursor)
        let nameMap = try parseNameMap(&cursor)
        let ports = try parsePorts(&cursor)
        var nets: [SPEFNetBlock] = []

        while !cursor.isAtEnd {
            if cursor.currentKeyword == "D_NET" {
                let net = try parseNetBlock(&cursor)
                nets.append(net)
            } else if let keyword = cursor.currentKeyword {
                throw SPEFParserDiagnostic(
                    severity: .error,
                    message: "Unsupported top-level SPEF keyword *\(keyword)",
                    location: cursor.currentLocation
                )
            } else {
                cursor.advance()
            }
        }

        return SPEFParseTree(header: header, nameMap: nameMap, ports: ports, nets: nets)
    }

    private func rejectInvalidTokens(_ tokens: [SPEFToken.Located]) throws {
        for token in tokens {
            guard case .invalid(let message) = token.token else {
                continue
            }
            throw SPEFParserDiagnostic(
                severity: .error,
                message: message,
                location: token.location
            )
        }
    }

    // MARK: - Header parsing

    private func parseHeader(_ cursor: inout TokenCursor) throws -> SPEFHeader {
        var spefVersion: String?
        var designName: String?
        var date: String?
        var vendor: String?
        var program: String?
        var divider: String?
        var delimiter: String?
        var busOpen: String?
        var busClose: String?
        var timeUnit: String?
        var timeScale: Double?
        var capUnit: String?
        var capScale: Double?
        var resUnit: String?
        var resScale: Double?
        var inductUnit: String?
        var inductScale: Double?

        // Parse header keywords until we hit a non-header keyword
        cursor.skipNewlines()
        while !cursor.isAtEnd {
            guard let kw = cursor.currentKeyword else { break }

            switch kw {
            case "SPEF":
                cursor.advance()
                spefVersion = try requireString(&cursor, field: "*SPEF")
            case "DESIGN":
                cursor.advance()
                designName = try requireString(&cursor, field: "*DESIGN")
            case "DATE":
                cursor.advance()
                date = try requireString(&cursor, field: "*DATE")
            case "VENDOR":
                cursor.advance()
                vendor = try requireString(&cursor, field: "*VENDOR")
            case "PROGRAM":
                cursor.advance()
                program = try requireString(&cursor, field: "*PROGRAM")
            case "DESIGN_FLOW":
                cursor.advance()
                cursor.skipUntilLineEnd()
            case "DIVIDER":
                cursor.advance()
                divider = try requireIdentifierOrPunctuation(&cursor, field: "*DIVIDER")
            case "DELIMITER":
                cursor.advance()
                delimiter = try requireIdentifierOrPunctuation(&cursor, field: "*DELIMITER")
            case "BUS_DELIMITER":
                cursor.advance()
                busOpen = try requireIdentifierOrPunctuation(&cursor, field: "*BUS_DELIMITER")
                busClose = try requireIdentifierOrPunctuation(&cursor, field: "*BUS_DELIMITER")
            case "T_UNIT":
                cursor.advance()
                timeScale = try requireNumber(&cursor, field: "*T_UNIT")
                timeUnit = try requireIdentifier(&cursor, field: "*T_UNIT")
            case "C_UNIT":
                cursor.advance()
                capScale = try requireNumber(&cursor, field: "*C_UNIT")
                capUnit = try requireIdentifier(&cursor, field: "*C_UNIT")
            case "R_UNIT":
                cursor.advance()
                resScale = try requireNumber(&cursor, field: "*R_UNIT")
                resUnit = try requireIdentifier(&cursor, field: "*R_UNIT")
            case "L_UNIT":
                cursor.advance()
                inductScale = try requireNumber(&cursor, field: "*L_UNIT")
                inductUnit = try requireIdentifier(&cursor, field: "*L_UNIT")
            case "VERSION":
                cursor.advance()
                _ = try requireString(&cursor, field: "*VERSION")
            case "NAME_MAP", "PORTS", "D_NET":
                break // End of header section
            default:
                throw SPEFParserDiagnostic(
                    severity: .error,
                    message: "Unsupported SPEF header keyword *\(kw)",
                    location: cursor.currentLocation
                )
            }

            if kw == "NAME_MAP" || kw == "PORTS" || kw == "D_NET" { break }
            cursor.skipNewlines()
        }

        guard let spefVersion else {
            throw diagnostic("Missing required SPEF header keyword *SPEF", location: cursor.currentLocation)
        }
        guard let designName else {
            throw diagnostic("Missing required SPEF header keyword *DESIGN", location: cursor.currentLocation)
        }
        guard let divider else {
            throw diagnostic("Missing required SPEF header keyword *DIVIDER", location: cursor.currentLocation)
        }
        guard let delimiter else {
            throw diagnostic("Missing required SPEF header keyword *DELIMITER", location: cursor.currentLocation)
        }
        guard let busOpen, let busClose else {
            throw diagnostic("Missing required SPEF header keyword *BUS_DELIMITER", location: cursor.currentLocation)
        }
        guard let timeUnit, let timeScale else {
            throw diagnostic("Missing required SPEF header keyword *T_UNIT", location: cursor.currentLocation)
        }
        guard let capUnit, let capScale else {
            throw diagnostic("Missing required SPEF header keyword *C_UNIT", location: cursor.currentLocation)
        }
        guard let resUnit, let resScale else {
            throw diagnostic("Missing required SPEF header keyword *R_UNIT", location: cursor.currentLocation)
        }

        return SPEFHeader(
            spefVersion: spefVersion, designName: designName,
            date: date, vendor: vendor, program: program,
            divider: divider, delimiter: delimiter,
            busDelimiterOpen: busOpen, busDelimiterClose: busClose,
            timeUnit: timeUnit, timeScaleFactor: timeScale,
            capUnit: capUnit, capScaleFactor: capScale,
            resUnit: resUnit, resScaleFactor: resScale,
            inductUnit: inductUnit, inductScaleFactor: inductScale
        )
    }

    // MARK: - Name Map

    private func parseNameMap(_ cursor: inout TokenCursor) throws -> [Int: String] {
        var map: [Int: String] = [:]
        guard cursor.currentKeyword == "NAME_MAP" else { return map }
        cursor.advance() // consume *NAME_MAP
        cursor.skipNewlines()

        while !cursor.isAtEnd {
            if cursor.currentKeyword != nil { break }
            if case .mappedName(let id) = cursor.currentToken {
                cursor.advance()
                map[id] = try requireIdentifier(&cursor, field: "*NAME_MAP")
            } else {
                throw diagnostic("Malformed SPEF name map entry", location: cursor.currentLocation)
            }
            cursor.skipNewlines()
        }
        return map
    }

    // MARK: - Ports

    private func parsePorts(_ cursor: inout TokenCursor) throws -> [SPEFPort] {
        var ports: [SPEFPort] = []
        guard cursor.currentKeyword == "PORTS" else { return ports }
        cursor.advance() // consume *PORTS
        cursor.skipNewlines()

        while !cursor.isAtEnd {
            if cursor.currentKeyword != nil { break }
            let name = try requireIdentifier(&cursor, field: "*PORTS")
            let dirStr = try requireIdentifier(&cursor, field: "*PORTS")
            guard let direction = SPEFDirection(rawValue: dirStr) else {
                throw diagnostic("Invalid SPEF port direction '\(dirStr)'", location: cursor.currentLocation)
            }
            // Optional coordinates
            var coordinate: Point2D?
            if let x = cursor.consumeNumber(), let y = cursor.consumeNumber() {
                coordinate = Point2D(x: x, y: y)
            }
            ports.append(SPEFPort(name: name, direction: direction, coordinate: coordinate))
            cursor.skipNewlines()
        }
        return ports
    }

    // MARK: - Net Block

    private func parseNetBlock(_ cursor: inout TokenCursor) throws -> SPEFNetBlock {
        guard cursor.currentKeyword == "D_NET" else {
            throw SPEFParserDiagnostic(severity: .error, message: "Expected *D_NET keyword")
        }
        cursor.advance() // consume *D_NET

        let netName = try requireIdentifier(&cursor, field: "*D_NET")
        let totalCap = try requireNumber(&cursor, field: "*D_NET")
        cursor.skipNewlines()

        var connections: [SPEFConnection] = []
        var capacitors: [SPEFCapacitor] = []
        var resistors: [SPEFResistor] = []

        while !cursor.isAtEnd {
            guard let kw = cursor.currentKeyword else {
                cursor.advance()
                cursor.skipNewlines()
                continue
            }

            switch kw {
            case "CONN":
                cursor.advance()
                cursor.skipNewlines()
                connections = try parseConnections(&cursor)
            case "CAP":
                cursor.advance()
                cursor.skipNewlines()
                capacitors = try parseCapacitors(&cursor)
            case "RES":
                cursor.advance()
                cursor.skipNewlines()
                resistors = try parseResistors(&cursor)
            case "END":
                cursor.advance()
                cursor.skipNewlines()
                return SPEFNetBlock(
                    netName: netName, totalCap: totalCap,
                    connections: connections, capacitors: capacitors, resistors: resistors
                )
            default:
                throw SPEFParserDiagnostic(
                    severity: .error,
                    message: "Unsupported SPEF net section *\(kw)",
                    location: cursor.currentLocation
                )
            }
        }

        throw diagnostic("Unterminated SPEF net block *D_NET \(netName)", location: cursor.currentLocation)
    }

    private func parseConnections(_ cursor: inout TokenCursor) throws -> [SPEFConnection] {
        var connections: [SPEFConnection] = []
        while !cursor.isAtEnd {
            if let kw = cursor.currentKeyword {
                // *I and *P are connection type markers, not section keywords
                if kw == "I" || kw == "P" {
                    guard let connType = SPEFConnType(rawValue: kw) else {
                        throw diagnostic("Invalid SPEF connection type *\(kw)", location: cursor.currentLocation)
                    }
                    cursor.advance() // consume *I or *P keyword
                    let name = try requireIdentifier(&cursor, field: "*\(kw)")
                    let dirStr = try requireIdentifier(&cursor, field: "*\(kw)")
                    guard let direction = SPEFDirection(rawValue: dirStr) else {
                        throw diagnostic("Invalid SPEF connection direction '\(dirStr)'", location: cursor.currentLocation)
                    }
                    connections.append(SPEFConnection(type: connType, name: name, direction: direction, coordinate: nil))
                    cursor.skipUntilLineEnd()
                    cursor.skipNewlines()
                    continue
                } else {
                    break // Any other keyword (*CAP, *RES, *END, etc.) terminates CONN section
                }
            }
            throw diagnostic("Malformed SPEF connection entry", location: cursor.currentLocation)
        }
        return connections
    }

    private func parseCapacitors(_ cursor: inout TokenCursor) throws -> [SPEFCapacitor] {
        var caps: [SPEFCapacitor] = []
        while !cursor.isAtEnd {
            if cursor.currentKeyword != nil { break }

            let id = try requireIntNumber(&cursor, field: "*CAP")
            let nodeA = try requireIdentifier(&cursor, field: "*CAP")
            switch cursor.currentToken {
            case .number:
                let value = try requireNumber(&cursor, field: "*CAP")
                caps.append(SPEFCapacitor(id: id, nodeA: nodeA, nodeB: nil, value: value))
            case .identifier, .mappedName:
                let nodeB = try requireIdentifier(&cursor, field: "*CAP")
                let value = try requireNumber(&cursor, field: "*CAP")
                caps.append(SPEFCapacitor(id: id, nodeA: nodeA, nodeB: nodeB, value: value))
            default:
                throw diagnostic("Malformed SPEF capacitor entry", location: cursor.currentLocation)
            }
            cursor.skipNewlines()
        }
        return caps
    }

    private func parseResistors(_ cursor: inout TokenCursor) throws -> [SPEFResistor] {
        var resistors: [SPEFResistor] = []
        while !cursor.isAtEnd {
            if cursor.currentKeyword != nil { break }

            let id = try requireIntNumber(&cursor, field: "*RES")
            let nodeA = try requireIdentifier(&cursor, field: "*RES")
            let nodeB = try requireIdentifier(&cursor, field: "*RES")
            let value = try requireNumber(&cursor, field: "*RES")
            resistors.append(SPEFResistor(id: id, nodeA: nodeA, nodeB: nodeB, value: value))
            cursor.skipNewlines()
        }
        return resistors
    }

    private func requireString(_ cursor: inout TokenCursor, field: String) throws -> String {
        guard let value = cursor.consumeString(), !value.isEmpty else {
            throw diagnostic("Expected string value for \(field)", location: cursor.currentLocation)
        }
        return value
    }

    private func requireIdentifier(_ cursor: inout TokenCursor, field: String) throws -> String {
        guard let value = cursor.consumeIdentifier(), !value.isEmpty else {
            throw diagnostic("Expected identifier value for \(field)", location: cursor.currentLocation)
        }
        return value
    }

    private func requireIdentifierOrPunctuation(_ cursor: inout TokenCursor, field: String) throws -> String {
        guard let value = cursor.consumeIdentifierOrPunctuation(), !value.isEmpty else {
            throw diagnostic("Expected identifier or punctuation value for \(field)", location: cursor.currentLocation)
        }
        return value
    }

    private func requireNumber(_ cursor: inout TokenCursor, field: String) throws -> Double {
        guard let value = cursor.consumeNumber() else {
            throw diagnostic("Expected numeric value for \(field)", location: cursor.currentLocation)
        }
        return value
    }

    private func requireIntNumber(_ cursor: inout TokenCursor, field: String) throws -> Int {
        guard let value = cursor.consumeIntNumber() else {
            throw diagnostic("Expected integer value for \(field)", location: cursor.currentLocation)
        }
        return value
    }

    private func diagnostic(_ message: String, location: SPEFSourceLocation?) -> SPEFParserDiagnostic {
        SPEFParserDiagnostic(severity: .error, message: message, location: location)
    }
}

// MARK: - Token Cursor

struct TokenCursor: Sendable {
    let tokens: [SPEFToken.Located]
    var index: Int = 0

    var isAtEnd: Bool {
        index >= tokens.count || currentToken == .endOfFile
    }

    var currentToken: SPEFToken {
        guard index < tokens.count else { return .endOfFile }
        return tokens[index].token
    }

    var currentKeyword: String? {
        if case .keyword(let kw) = currentToken { return kw }
        return nil
    }

    var currentLocation: SPEFSourceLocation? {
        guard index < tokens.count else { return nil }
        return tokens[index].location
    }

    mutating func advance() {
        if index < tokens.count { index += 1 }
    }

    mutating func skipNewlines() {
        while index < tokens.count, case .newline = tokens[index].token {
            index += 1
        }
    }

    mutating func skipUntilLineEnd() {
        while index < tokens.count {
            switch tokens[index].token {
            case .newline, .endOfFile:
                return
            default:
                index += 1
            }
        }
    }

    mutating func skipToNextKeyword() {
        while index < tokens.count {
            if case .keyword(_) = tokens[index].token { return }
            index += 1
        }
    }

    mutating func consumeString() -> String? {
        skipNewlines()
        guard index < tokens.count else { return nil }
        if case .string(let s) = tokens[index].token {
            index += 1
            return s
        }
        return nil
    }

    mutating func consumeIdentifier() -> String? {
        skipNewlines()
        guard index < tokens.count else { return nil }
        guard var value = consumeIdentifierComponent() else {
            return nil
        }

        while index < tokens.count {
            guard case .colon = tokens[index].token else {
                break
            }
            index += 1
            guard let suffix = consumeIdentifierComponent() else {
                return nil
            }
            value += ":\(suffix)"
        }

        return value
    }

    mutating func consumeIdentifierOrPunctuation() -> String? {
        skipNewlines()
        guard index < tokens.count else { return nil }
        switch tokens[index].token {
        case .identifier(let s):
            index += 1
            return s
        case .slash:
            index += 1
            return "/"
        case .colon:
            index += 1
            return ":"
        case .leftBracket:
            index += 1
            return "["
        case .rightBracket:
            index += 1
            return "]"
        default:
            return nil
        }
    }

    mutating func consumeNumber() -> Double? {
        skipNewlines()
        guard index < tokens.count else { return nil }
        if case .number(let n) = tokens[index].token {
            index += 1
            return n
        }
        return nil
    }

    mutating func consumeIntNumber() -> Int? {
        skipNewlines()
        guard index < tokens.count else { return nil }
        if case .number(let n) = tokens[index].token {
            index += 1
            return Int(n)
        }
        return nil
    }

    func peekNumber() -> Double? {
        var i = index
        while i < tokens.count, case .newline = tokens[i].token { i += 1 }
        guard i < tokens.count else { return nil }
        if case .number(let n) = tokens[i].token { return n }
        return nil
    }

    private mutating func consumeIdentifierComponent() -> String? {
        guard index < tokens.count else {
            return nil
        }

        switch tokens[index].token {
        case .identifier(let s):
            index += 1
            return s
        case .mappedName(let id):
            index += 1
            return "*\(id)"
        case .number(let value):
            index += 1
            if value.rounded() == value {
                return "\(Int(value))"
            }
            return "\(value)"
        default:
            return nil
        }
    }
}
