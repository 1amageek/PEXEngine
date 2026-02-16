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
        var cursor = TokenCursor(tokens: tokens)

        let header = try parseHeader(&cursor)
        let nameMap = parseNameMap(&cursor)
        let ports = parsePorts(&cursor)
        var nets: [SPEFNetBlock] = []

        while !cursor.isAtEnd {
            if cursor.currentKeyword == "D_NET" {
                let net = try parseNetBlock(&cursor)
                nets.append(net)
            } else {
                cursor.advance()
            }
        }

        return SPEFParseTree(header: header, nameMap: nameMap, ports: ports, nets: nets)
    }

    // MARK: - Header parsing

    private func parseHeader(_ cursor: inout TokenCursor) throws -> SPEFHeader {
        var spefVersion = ""
        var designName = ""
        var date: String?
        var vendor: String?
        var program: String?
        var divider = "/"
        var delimiter = ":"
        var busOpen = "["
        var busClose = "]"
        var timeUnit = "NS"
        var timeScale = 1.0
        var capUnit = "PF"
        var capScale = 1.0
        var resUnit = "OHM"
        var resScale = 1.0
        var inductUnit: String?
        var inductScale: Double?

        // Parse header keywords until we hit a non-header keyword
        while !cursor.isAtEnd {
            guard let kw = cursor.currentKeyword else { break }

            switch kw {
            case "SPEF":
                cursor.advance()
                spefVersion = cursor.consumeString() ?? ""
            case "DESIGN":
                cursor.advance()
                designName = cursor.consumeString() ?? ""
            case "DATE":
                cursor.advance()
                date = cursor.consumeString()
            case "VENDOR":
                cursor.advance()
                vendor = cursor.consumeString()
            case "PROGRAM":
                cursor.advance()
                program = cursor.consumeString()
            case "DESIGN_FLOW":
                cursor.advance()
                _ = cursor.consumeString()
            case "DIVIDER":
                cursor.advance()
                divider = cursor.consumeIdentifierOrPunctuation() ?? "/"
            case "DELIMITER":
                cursor.advance()
                delimiter = cursor.consumeIdentifierOrPunctuation() ?? ":"
            case "BUS_DELIMITER":
                cursor.advance()
                busOpen = cursor.consumeIdentifierOrPunctuation() ?? "["
                busClose = cursor.consumeIdentifierOrPunctuation() ?? "]"
            case "T_UNIT":
                cursor.advance()
                timeScale = cursor.consumeNumber() ?? 1.0
                timeUnit = cursor.consumeIdentifier() ?? "NS"
            case "C_UNIT":
                cursor.advance()
                capScale = cursor.consumeNumber() ?? 1.0
                capUnit = cursor.consumeIdentifier() ?? "PF"
            case "R_UNIT":
                cursor.advance()
                resScale = cursor.consumeNumber() ?? 1.0
                resUnit = cursor.consumeIdentifier() ?? "OHM"
            case "L_UNIT":
                cursor.advance()
                inductScale = cursor.consumeNumber()
                inductUnit = cursor.consumeIdentifier()
            case "VERSION":
                cursor.advance()
                _ = cursor.consumeString()
            case "NAME_MAP", "PORTS", "D_NET":
                break // End of header section
            default:
                cursor.advance()
                cursor.skipToNextKeyword()
                continue
            }

            if kw == "NAME_MAP" || kw == "PORTS" || kw == "D_NET" { break }
            cursor.skipNewlines()
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

    private func parseNameMap(_ cursor: inout TokenCursor) -> [Int: String] {
        var map: [Int: String] = [:]
        guard cursor.currentKeyword == "NAME_MAP" else { return map }
        cursor.advance() // consume *NAME_MAP
        cursor.skipNewlines()

        while !cursor.isAtEnd {
            if cursor.currentKeyword != nil { break }
            if case .mappedName(let id) = cursor.currentToken {
                cursor.advance()
                if let name = cursor.consumeIdentifier() {
                    map[id] = name
                }
            } else {
                cursor.advance()
            }
            cursor.skipNewlines()
        }
        return map
    }

    // MARK: - Ports

    private func parsePorts(_ cursor: inout TokenCursor) -> [SPEFPort] {
        var ports: [SPEFPort] = []
        guard cursor.currentKeyword == "PORTS" else { return ports }
        cursor.advance() // consume *PORTS
        cursor.skipNewlines()

        while !cursor.isAtEnd {
            if cursor.currentKeyword != nil { break }
            if let name = cursor.consumeIdentifier() {
                let dirStr = cursor.consumeIdentifier() ?? "B"
                let direction = SPEFDirection(rawValue: dirStr) ?? .bidirectional
                // Optional coordinates
                var coordinate: Point2D?
                if let x = cursor.consumeNumber(), let y = cursor.consumeNumber() {
                    coordinate = Point2D(x: x, y: y)
                }
                ports.append(SPEFPort(name: name, direction: direction, coordinate: coordinate))
            } else {
                cursor.advance()
            }
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

        let netName = cursor.consumeIdentifier() ?? ""
        let totalCap = cursor.consumeNumber() ?? 0.0
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
                connections = parseConnections(&cursor)
            case "CAP":
                cursor.advance()
                cursor.skipNewlines()
                capacitors = parseCapacitors(&cursor)
            case "RES":
                cursor.advance()
                cursor.skipNewlines()
                resistors = parseResistors(&cursor)
            case "END":
                cursor.advance()
                cursor.skipNewlines()
                return SPEFNetBlock(
                    netName: netName, totalCap: totalCap,
                    connections: connections, capacitors: capacitors, resistors: resistors
                )
            default:
                // Unknown section, skip
                cursor.advance()
                cursor.skipNewlines()
            }
        }

        return SPEFNetBlock(
            netName: netName, totalCap: totalCap,
            connections: connections, capacitors: capacitors, resistors: resistors
        )
    }

    private func parseConnections(_ cursor: inout TokenCursor) -> [SPEFConnection] {
        var connections: [SPEFConnection] = []
        while !cursor.isAtEnd {
            if let kw = cursor.currentKeyword {
                // *I and *P are connection type markers, not section keywords
                if kw == "I" || kw == "P" {
                    let connType = SPEFConnType(rawValue: kw) ?? .instancePin
                    cursor.advance() // consume *I or *P keyword
                    let name = cursor.consumeIdentifier() ?? ""
                    let dirStr = cursor.consumeIdentifier() ?? "B"
                    let direction = SPEFDirection(rawValue: dirStr) ?? .bidirectional
                    connections.append(SPEFConnection(type: connType, name: name, direction: direction, coordinate: nil))
                    cursor.skipNewlines()
                    continue
                } else {
                    break // Any other keyword (*CAP, *RES, *END, etc.) terminates CONN section
                }
            }
            cursor.advance()
            cursor.skipNewlines()
        }
        return connections
    }

    private func parseCapacitors(_ cursor: inout TokenCursor) -> [SPEFCapacitor] {
        var caps: [SPEFCapacitor] = []
        while !cursor.isAtEnd {
            if cursor.currentKeyword != nil { break }

            if let id = cursor.consumeIntNumber() {
                let nodeA = cursor.consumeIdentifier() ?? ""
                // Peek: if next is a number, it's a ground cap (nodeA + value)
                // If next is an identifier, it's a coupling cap (nodeA + nodeB + value)
                if let nextNum = cursor.peekNumber() {
                    // Ground cap or look-ahead
                    let nodeOrValue = cursor.consumeIdentifier()
                    if let nodeOrValue, let value = cursor.consumeNumber() {
                        // nodeA, nodeB, value
                        caps.append(SPEFCapacitor(id: id, nodeA: nodeA, nodeB: nodeOrValue, value: value))
                    } else {
                        // nodeA, value (ground cap)
                        caps.append(SPEFCapacitor(id: id, nodeA: nodeA, nodeB: nil, value: nextNum))
                        _ = cursor.consumeNumber() // consume the peeked number
                    }
                } else if let secondToken = cursor.consumeIdentifier() {
                    if let value = cursor.consumeNumber() {
                        // nodeA, nodeB(secondToken), value
                        caps.append(SPEFCapacitor(id: id, nodeA: nodeA, nodeB: secondToken, value: value))
                    } else {
                        // Malformed, treat as ground cap with 0
                        caps.append(SPEFCapacitor(id: id, nodeA: nodeA, nodeB: nil, value: 0))
                    }
                } else if let value = cursor.consumeNumber() {
                    caps.append(SPEFCapacitor(id: id, nodeA: nodeA, nodeB: nil, value: value))
                }
            } else {
                cursor.advance()
            }
            cursor.skipNewlines()
        }
        return caps
    }

    private func parseResistors(_ cursor: inout TokenCursor) -> [SPEFResistor] {
        var resistors: [SPEFResistor] = []
        while !cursor.isAtEnd {
            if cursor.currentKeyword != nil { break }

            if let id = cursor.consumeIntNumber() {
                let nodeA = cursor.consumeIdentifier() ?? ""
                let nodeB = cursor.consumeIdentifier() ?? ""
                let value = cursor.consumeNumber() ?? 0.0
                resistors.append(SPEFResistor(id: id, nodeA: nodeA, nodeB: nodeB, value: value))
            } else {
                cursor.advance()
            }
            cursor.skipNewlines()
        }
        return resistors
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

    mutating func advance() {
        if index < tokens.count { index += 1 }
    }

    mutating func skipNewlines() {
        while index < tokens.count, case .newline = tokens[index].token {
            index += 1
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
        switch tokens[index].token {
        case .identifier(let s):
            index += 1
            return s
        default:
            return nil
        }
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
}
