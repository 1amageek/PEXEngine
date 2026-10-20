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
    public let nodeCoordinates: [SPEFNodeCoordinate]
    public let capacitors: [SPEFCapacitor]
    public let resistors: [SPEFResistor]
    public let inductors: [SPEFInductor]
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

public struct SPEFNodeCoordinate: Sendable {
    public let name: String
    public let coordinate: Point2D
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

public struct SPEFInductor: Sendable {
    public let id: Int
    public let nodeA: String
    public let nodeB: String
    public let value: Double
}

// MARK: - SPEF Parser

public struct SPEFParser: Sendable {
    private let resources: PEXParserResourceScope?

    public init() { resources = nil }

    private init(resources: PEXParserResourceScope) { self.resources = resources }

    public func parse(tokens: [SPEFToken.Located], control: any PEXParserResourceControlling)
        throws -> (value: SPEFParseTree, retention: PEXParserRetention) {
        var textBytes = 0
        for token in tokens {
            try control.checkpoint(workUnits: 1)
            switch token.token {
            case .keyword(let text), .identifier(let text), .string(let text), .invalid(let text):
                textBytes = try PEXParserStorageSize.add(textBytes, text.utf8.count)
            default: break
            }
        }
        // Each parsed row consumes at least one input token. Reserve each distinct
        // row shape, including old/new section replacement, before entering parse.
        var retained = MemoryLayout<SPEFParseTree>.stride
        let rowStride = MemoryLayout<SPEFPort>.stride + MemoryLayout<SPEFNetBlock>.stride
            + MemoryLayout<SPEFConnection>.stride + MemoryLayout<SPEFNodeCoordinate>.stride
            + MemoryLayout<SPEFCapacitor>.stride + MemoryLayout<SPEFResistor>.stride
            + MemoryLayout<SPEFInductor>.stride + MemoryLayout<(Int, String)>.stride
        retained = try PEXParserStorageSize.add(retained,
            PEXParserStorageSize.multiply(tokens.count, rowStride))
        // Numeric identifier components add at most the decimal Int/binary64
        // spelling capacity; colon concatenations consume existing text once.
        let synthesizedText = try PEXParserStorageSize.add(textBytes,
            PEXParserStorageSize.multiply(tokens.count, 24))
        retained = try PEXParserStorageSize.add(retained,
            PEXParserStorageSize.multiply(synthesizedText, 2))
        let scope = try PEXParserResourceScope(control: control, retained: UInt64(retained),
            temporary: UInt64(retained))
        let value = try Self(resources: scope).parse(tokens: tokens)
        try scope.check(0)
        return (value, scope.retention)
    }

    public func parse(tokens: [SPEFToken.Located]) throws -> SPEFParseTree {
        try rejectInvalidTokens(tokens)
        var cursor = TokenCursor(tokens: tokens, resources: resources)

        let header = try parseHeader(&cursor)
        let nameMap = try parseNameMap(&cursor)
        let ports = try parsePorts(&cursor)
        var nets: [SPEFNetBlock] = []

        while !cursor.isAtEnd {
            try resources?.check()
            if cursor.currentKeyword == "D_NET" {
                let net = try parseNetBlock(&cursor)
                nets.append(net)
            } else if let keyword = cursor.currentKeyword {
                throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Unsupported top-level SPEF keyword *".utf8.count, keyword.utf8.count)) {
                    SPEFParserDiagnostic(
                        severity: .error,
                        message: "Unsupported top-level SPEF keyword *\(keyword)",
                        location: cursor.currentLocation
                    )
                }
            } else {
                try cursor.advance()
            }
        }

        return SPEFParseTree(header: header, nameMap: nameMap, ports: ports, nets: nets)
    }

    private func rejectInvalidTokens(_ tokens: [SPEFToken.Located]) throws {
        for token in tokens {
            try resources?.check()
            guard case .invalid(let message) = token.token else {
                continue
            }
            throw try sourceFailure(diagnosticBytes: message.utf8.count) {
                SPEFParserDiagnostic(
                    severity: .error,
                    message: message,
                    location: token.location
                )
            }
        }
    }

    // MARK: - Header parsing

    private func parseHeader(_ cursor: inout TokenCursor) throws -> SPEFHeader {
        var fields = SPEFHeaderFields(resources: resources)
        try cursor.skipNewlines()
        while !cursor.isAtEnd {
            try resources?.check()
            guard let kw = cursor.currentKeyword else { break }
            if isHeaderTerminator(kw) { break }

            try parseHeaderKeyword(kw, cursor: &cursor, fields: &fields)
            try cursor.skipNewlines()
        }

        return try fields.build(location: cursor.currentLocation)
    }

    private func isHeaderTerminator(_ keyword: String) -> Bool {
        keyword == "NAME_MAP" || keyword == "PORTS" || keyword == "D_NET"
    }

    private func parseHeaderKeyword(
        _ keyword: String,
        cursor: inout TokenCursor,
        fields: inout SPEFHeaderFields
    ) throws {
        let location = cursor.currentLocation
        switch keyword {
        case "SPEF":
            try cursor.advance()
            let value = try requireString(&cursor, field: "*SPEF")
            try assignUnique(value, to: &fields.spefVersion, keyword: "*SPEF", location: location)
        case "DESIGN":
            try cursor.advance()
            let value = try requireString(&cursor, field: "*DESIGN")
            try assignUnique(value, to: &fields.designName, keyword: "*DESIGN", location: location)
        case "DATE":
            try cursor.advance()
            let value = try requireString(&cursor, field: "*DATE")
            try assignUnique(value, to: &fields.date, keyword: "*DATE", location: location)
        case "VENDOR":
            try cursor.advance()
            let value = try requireString(&cursor, field: "*VENDOR")
            try assignUnique(value, to: &fields.vendor, keyword: "*VENDOR", location: location)
        case "PROGRAM":
            try cursor.advance()
            let value = try requireString(&cursor, field: "*PROGRAM")
            try assignUnique(value, to: &fields.program, keyword: "*PROGRAM", location: location)
        case "DESIGN_FLOW":
            try cursor.advance()
            try cursor.skipUntilLineEnd()
        case "DIVIDER":
            try cursor.advance()
            let value = try requireIdentifierOrPunctuation(&cursor, field: "*DIVIDER")
            try assignUnique(value, to: &fields.divider, keyword: "*DIVIDER", location: location)
        case "DELIMITER":
            try cursor.advance()
            let value = try requireIdentifierOrPunctuation(&cursor, field: "*DELIMITER")
            try assignUnique(value, to: &fields.delimiter, keyword: "*DELIMITER", location: location)
        case "BUS_DELIMITER":
            try cursor.advance()
            let open = try requireIdentifierOrPunctuation(&cursor, field: "*BUS_DELIMITER")
            let close = try requireIdentifierOrPunctuation(&cursor, field: "*BUS_DELIMITER")
            try assignUniquePair(
                open,
                close,
                toFirst: &fields.busOpen,
                toSecond: &fields.busClose,
                keyword: "*BUS_DELIMITER",
                location: location
            )
        case "T_UNIT":
            try cursor.advance()
            let scale = try requireNumber(&cursor, field: "*T_UNIT")
            let unit = try requireIdentifier(&cursor, field: "*T_UNIT")
            try assignUniquePair(
                scale,
                unit,
                toFirst: &fields.timeScale,
                toSecond: &fields.timeUnit,
                keyword: "*T_UNIT",
                location: location
            )
        case "C_UNIT":
            try cursor.advance()
            let scale = try requireNumber(&cursor, field: "*C_UNIT")
            let unit = try requireIdentifier(&cursor, field: "*C_UNIT")
            try assignUniquePair(
                scale,
                unit,
                toFirst: &fields.capScale,
                toSecond: &fields.capUnit,
                keyword: "*C_UNIT",
                location: location
            )
        case "R_UNIT":
            try cursor.advance()
            let scale = try requireNumber(&cursor, field: "*R_UNIT")
            let unit = try requireIdentifier(&cursor, field: "*R_UNIT")
            try assignUniquePair(
                scale,
                unit,
                toFirst: &fields.resScale,
                toSecond: &fields.resUnit,
                keyword: "*R_UNIT",
                location: location
            )
        case "L_UNIT":
            try cursor.advance()
            let scale = try requireNumber(&cursor, field: "*L_UNIT")
            let unit = try requireIdentifier(&cursor, field: "*L_UNIT")
            try assignUniquePair(
                scale,
                unit,
                toFirst: &fields.inductScale,
                toSecond: &fields.inductUnit,
                keyword: "*L_UNIT",
                location: location
            )
        case "VERSION":
            try cursor.advance()
            let value = try requireString(&cursor, field: "*VERSION")
            try assignUnique(value, to: &fields.version, keyword: "*VERSION", location: location)
        default:
            throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Unsupported SPEF header keyword *".utf8.count, keyword.utf8.count)) {
                SPEFParserDiagnostic(
                    severity: .error,
                    message: "Unsupported SPEF header keyword *\(keyword)",
                    location: cursor.currentLocation
                )
            }
        }
    }

    private func assignUnique<T>(
        _ value: T,
        to storage: inout T?,
        keyword: String,
        location: SPEFSourceLocation?
    ) throws {
        if case .some = storage {
            throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Duplicate SPEF header keyword ".utf8.count, keyword.utf8.count)) {
                diagnostic("Duplicate SPEF header keyword \(keyword)", location: location)
            }
        }
        storage = value
    }

    private func assignUniquePair<First, Second>(
        _ first: First,
        _ second: Second,
        toFirst firstStorage: inout First?,
        toSecond secondStorage: inout Second?,
        keyword: String,
        location: SPEFSourceLocation?
    ) throws {
        if case .some = firstStorage {
            throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Duplicate SPEF header keyword ".utf8.count, keyword.utf8.count)) {
                diagnostic("Duplicate SPEF header keyword \(keyword)", location: location)
            }
        }
        if case .some = secondStorage {
            throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Duplicate SPEF header keyword ".utf8.count, keyword.utf8.count)) {
                diagnostic("Duplicate SPEF header keyword \(keyword)", location: location)
            }
        }
        firstStorage = first
        secondStorage = second
    }

    private struct SPEFHeaderFields {
        let resources: PEXParserResourceScope?
        var spefVersion: String?
        var designName: String?
        var date: String?
        var vendor: String?
        var program: String?
        var version: String?
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

        func build(location: SPEFSourceLocation?) throws -> SPEFHeader {
            let required = try requiredFields(location: location)

            return SPEFHeader(
                spefVersion: required.spefVersion,
                designName: required.designName,
                date: date,
                vendor: vendor,
                program: program,
                divider: required.divider,
                delimiter: required.delimiter,
                busDelimiterOpen: required.busOpen,
                busDelimiterClose: required.busClose,
                timeUnit: required.timeUnit,
                timeScaleFactor: required.timeScale,
                capUnit: required.capUnit,
                capScaleFactor: required.capScale,
                resUnit: required.resUnit,
                resScaleFactor: required.resScale,
                inductUnit: inductUnit,
                inductScaleFactor: inductScale
            )
        }

        private func requiredFields(location: SPEFSourceLocation?) throws -> RequiredSPEFHeaderFields {
            guard let spefVersion else {
                throw try missing("*SPEF", location: location)
            }
            guard let designName else {
                throw try missing("*DESIGN", location: location)
            }
            guard let divider else {
                throw try missing("*DIVIDER", location: location)
            }
            guard let delimiter else {
                throw try missing("*DELIMITER", location: location)
            }
            guard let busOpen, let busClose else {
                throw try missing("*BUS_DELIMITER", location: location)
            }
            guard let timeUnit, let timeScale else {
                throw try missing("*T_UNIT", location: location)
            }
            guard let capUnit, let capScale else {
                throw try missing("*C_UNIT", location: location)
            }
            guard let resUnit, let resScale else {
                throw try missing("*R_UNIT", location: location)
            }

            return RequiredSPEFHeaderFields(
                spefVersion: spefVersion,
                designName: designName,
                divider: divider,
                delimiter: delimiter,
                busOpen: busOpen,
                busClose: busClose,
                timeUnit: timeUnit,
                timeScale: timeScale,
                capUnit: capUnit,
                capScale: capScale,
                resUnit: resUnit,
                resScale: resScale
            )
        }

        private func missing(_ keyword: String, location: SPEFSourceLocation?) throws -> any Error {
            let make = {
                SPEFParserDiagnostic(severity: .error,
                    message: "Missing required SPEF header keyword \(keyword)", location: location)
            }
            guard let resources else { return make() }
            let bytes = try PEXParserStorageSize.add("Missing required SPEF header keyword ".utf8.count,
                keyword.utf8.count)
            return try resources.sourceFailure(diagnosticBytes: bytes, make)
        }
    }

    private struct RequiredSPEFHeaderFields {
        let spefVersion: String
        let designName: String
        let divider: String
        let delimiter: String
        let busOpen: String
        let busClose: String
        let timeUnit: String
        let timeScale: Double
        let capUnit: String
        let capScale: Double
        let resUnit: String
        let resScale: Double
    }

    // MARK: - Name Map

    private func parseNameMap(_ cursor: inout TokenCursor) throws -> [Int: String] {
        var map: [Int: String] = [:]
        guard cursor.currentKeyword == "NAME_MAP" else { return map }
        try cursor.advance() // consume *NAME_MAP
        try cursor.skipNewlines()

        while !cursor.isAtEnd {
            try resources?.check()
            if cursor.currentKeyword != nil { break }
            if case .mappedName(let id) = cursor.currentToken {
                guard map[id] == nil else {
                    throw try sourceFailure(diagnosticBytes: "Duplicate SPEF name map identifier".utf8.count) {
                diagnostic("Duplicate SPEF name map identifier", location: cursor.currentLocation)
            }
                }
                try cursor.advance()
                map[id] = try requireIdentifier(&cursor, field: "*NAME_MAP")
            } else {
                throw try sourceFailure(diagnosticBytes: "Malformed SPEF name map entry".utf8.count) {
                diagnostic("Malformed SPEF name map entry", location: cursor.currentLocation)
            }
            }
            try cursor.skipNewlines()
        }
        return map
    }

    // MARK: - Ports

    private func parsePorts(_ cursor: inout TokenCursor) throws -> [SPEFPort] {
        var ports: [SPEFPort] = []
        guard cursor.currentKeyword == "PORTS" else { return ports }
        try cursor.advance() // consume *PORTS
        try cursor.skipNewlines()

        while !cursor.isAtEnd {
            try resources?.check()
            if cursor.currentKeyword != nil { break }
            let name = try requireIdentifier(&cursor, field: "*PORTS")
            let dirStr = try requireIdentifier(&cursor, field: "*PORTS")
            guard let direction = SPEFDirection(rawValue: dirStr) else {
                throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Invalid SPEF port direction ''".utf8.count, dirStr.utf8.count)) {
                diagnostic("Invalid SPEF port direction '\(dirStr)'", location: cursor.currentLocation)
            }
            }
            let coordinate = try optionalCoordinate(&cursor)
            ports.append(SPEFPort(name: name, direction: direction, coordinate: coordinate))
            try cursor.skipNewlines()
        }
        return ports
    }

    // MARK: - Net Block

    private func parseNetBlock(_ cursor: inout TokenCursor) throws -> SPEFNetBlock {
        guard cursor.currentKeyword == "D_NET" else {
            throw try sourceFailure(diagnosticBytes: "Expected *D_NET keyword".utf8.count) {
                diagnostic("Expected *D_NET keyword", location: cursor.currentLocation)
            }
        }
        try cursor.advance() // consume *D_NET

        let netName = try requireIdentifier(&cursor, field: "*D_NET")
        let totalCap = try requireNumber(&cursor, field: "*D_NET")
        try cursor.skipNewlines()

        var sections = SPEFNetBlockSections()

        while !cursor.isAtEnd {
            try resources?.check()
            guard let keyword = cursor.currentKeyword else {
                throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Unexpected SPEF token inside *D_NET ".utf8.count, netName.utf8.count)) {
                diagnostic("Unexpected SPEF token inside *D_NET \(netName)", location: cursor.currentLocation)
            }
            }

            if let block = try parseNetSection(
                keyword,
                cursor: &cursor,
                sections: &sections,
                netName: netName,
                totalCap: totalCap
            ) {
                return block
            }
        }

        throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Unterminated SPEF net block *D_NET ".utf8.count, netName.utf8.count)) {
                diagnostic("Unterminated SPEF net block *D_NET \(netName)", location: cursor.currentLocation)
            }
    }

    private struct SPEFNetBlockSections {
        var connections: [SPEFConnection] = []
        var nodeCoordinates: [SPEFNodeCoordinate] = []
        var capacitors: [SPEFCapacitor] = []
        var resistors: [SPEFResistor] = []
        var inductors: [SPEFInductor] = []

        func makeBlock(netName: String, totalCap: Double) -> SPEFNetBlock {
            SPEFNetBlock(
                netName: netName,
                totalCap: totalCap,
                connections: connections,
                nodeCoordinates: nodeCoordinates,
                capacitors: capacitors,
                resistors: resistors,
                inductors: inductors
            )
        }
    }

    private func parseNetSection(
        _ keyword: String,
        cursor: inout TokenCursor,
        sections: inout SPEFNetBlockSections,
        netName: String,
        totalCap: Double
    ) throws -> SPEFNetBlock? {
        switch keyword {
        case "CONN":
            try cursor.advance()
            try cursor.skipNewlines()
            let parsed = try parseConnections(&cursor)
            sections.connections = parsed.connections
            sections.nodeCoordinates = parsed.nodeCoordinates
            return nil
        case "CAP":
            try cursor.advance()
            try cursor.skipNewlines()
            sections.capacitors = try parseCapacitors(&cursor)
            return nil
        case "RES":
            try cursor.advance()
            try cursor.skipNewlines()
            sections.resistors = try parseResistors(&cursor)
            return nil
        case "INDUC":
            try cursor.advance()
            try cursor.skipNewlines()
            sections.inductors = try parseInductors(&cursor)
            return nil
        case "END":
            try cursor.advance()
            try cursor.skipNewlines()
            return sections.makeBlock(netName: netName, totalCap: totalCap)
        default:
            throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Unsupported SPEF net section *".utf8.count, keyword.utf8.count)) {
                SPEFParserDiagnostic(
                    severity: .error,
                    message: "Unsupported SPEF net section *\(keyword)",
                    location: cursor.currentLocation
                )
            }
        }
    }

    private struct ParsedConnections {
        var connections: [SPEFConnection]
        var nodeCoordinates: [SPEFNodeCoordinate]
    }

    private func parseConnections(_ cursor: inout TokenCursor) throws -> ParsedConnections {
        var connections: [SPEFConnection] = []
        var nodeCoordinates: [SPEFNodeCoordinate] = []
        while !cursor.isAtEnd {
            try resources?.check()
            if let kw = cursor.currentKeyword {
                // *I and *P are connection type markers, not section keywords
                if kw == "I" || kw == "P" {
                    guard let connType = SPEFConnType(rawValue: kw) else {
                        throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Invalid SPEF connection type *".utf8.count, kw.utf8.count)) {
                diagnostic("Invalid SPEF connection type *\(kw)", location: cursor.currentLocation)
            }
                    }
                    try cursor.advance() // consume *I or *P keyword
                    let name = try requireIdentifier(&cursor, field: "*\(kw)")
                    let dirStr = try requireIdentifier(&cursor, field: "*\(kw)")
                    guard let direction = SPEFDirection(rawValue: dirStr) else {
                        throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Invalid SPEF connection direction ''".utf8.count, dirStr.utf8.count)) {
                diagnostic("Invalid SPEF connection direction '\(dirStr)'", location: cursor.currentLocation)
            }
                    }
                    let coordinate = try optionalCoordinate(&cursor)
                    connections.append(SPEFConnection(
                        type: connType,
                        name: name,
                        direction: direction,
                        coordinate: coordinate
                    ))
                    try cursor.skipUntilLineEnd()
                    try cursor.skipNewlines()
                    continue
                } else if kw == "N" {
                    try cursor.advance()
                    let name = try requireIdentifier(&cursor, field: "*N")
                    if let coordinate = try optionalCoordinate(&cursor) {
                        nodeCoordinates.append(SPEFNodeCoordinate(name: name, coordinate: coordinate))
                    }
                    try cursor.skipUntilLineEnd()
                    try cursor.skipNewlines()
                    continue
                } else {
                    break // Any other keyword (*CAP, *RES, *END, etc.) terminates CONN section
                }
            }
            throw try sourceFailure(diagnosticBytes: "Malformed SPEF connection entry".utf8.count) {
                diagnostic("Malformed SPEF connection entry", location: cursor.currentLocation)
            }
        }
        return ParsedConnections(connections: connections, nodeCoordinates: nodeCoordinates)
    }

    private func optionalCoordinate(_ cursor: inout TokenCursor) throws -> Point2D? {
        let startIndex = cursor.index
        if cursor.currentKeyword == "C" { try cursor.advance() }
        guard let x = try cursor.consumeNumber(),
              let y = try cursor.consumeNumber() else {
            cursor.index = startIndex
            return nil
        }
        return Point2D(x: x, y: y)
    }

    private func parseCapacitors(_ cursor: inout TokenCursor) throws -> [SPEFCapacitor] {
        var caps: [SPEFCapacitor] = []
        while !cursor.isAtEnd {
            try resources?.check()
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
                throw try sourceFailure(diagnosticBytes: "Malformed SPEF capacitor entry".utf8.count) {
                diagnostic("Malformed SPEF capacitor entry", location: cursor.currentLocation)
            }
            }
            try cursor.skipNewlines()
        }
        return caps
    }

    private func parseResistors(_ cursor: inout TokenCursor) throws -> [SPEFResistor] {
        var resistors: [SPEFResistor] = []
        while !cursor.isAtEnd {
            try resources?.check()
            if cursor.currentKeyword != nil { break }

            let id = try requireIntNumber(&cursor, field: "*RES")
            let nodeA = try requireIdentifier(&cursor, field: "*RES")
            let nodeB = try requireIdentifier(&cursor, field: "*RES")
            let value = try requireNumber(&cursor, field: "*RES")
            resistors.append(SPEFResistor(id: id, nodeA: nodeA, nodeB: nodeB, value: value))
            try cursor.skipNewlines()
        }
        return resistors
    }

    private func parseInductors(_ cursor: inout TokenCursor) throws -> [SPEFInductor] {
        var inductors: [SPEFInductor] = []
        while !cursor.isAtEnd {
            try resources?.check()
            if cursor.currentKeyword != nil { break }

            let id = try requireIntNumber(&cursor, field: "*INDUC")
            let nodeA = try requireIdentifier(&cursor, field: "*INDUC")
            let nodeB = try requireIdentifier(&cursor, field: "*INDUC")
            let value = try requireNumber(&cursor, field: "*INDUC")
            inductors.append(SPEFInductor(id: id, nodeA: nodeA, nodeB: nodeB, value: value))
            try cursor.skipNewlines()
        }
        return inductors
    }

    private func requireString(_ cursor: inout TokenCursor, field: String) throws -> String {
        guard let value = try cursor.consumeString(), !value.isEmpty else {
            throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Expected string value for ".utf8.count, field.utf8.count)) {
                diagnostic("Expected string value for \(field)", location: cursor.currentLocation)
            }
        }
        return value
    }

    private func requireIdentifier(_ cursor: inout TokenCursor, field: String) throws -> String {
        guard let value = try cursor.consumeIdentifier(), !value.isEmpty else {
            throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Expected identifier value for ".utf8.count, field.utf8.count)) {
                diagnostic("Expected identifier value for \(field)", location: cursor.currentLocation)
            }
        }
        return value
    }

    private func requireIdentifierOrPunctuation(_ cursor: inout TokenCursor, field: String) throws -> String {
        guard let value = try cursor.consumeIdentifierOrPunctuation(), !value.isEmpty else {
            throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Expected identifier or punctuation value for ".utf8.count, field.utf8.count)) {
                diagnostic("Expected identifier or punctuation value for \(field)", location: cursor.currentLocation)
            }
        }
        return value
    }

    private func requireNumber(_ cursor: inout TokenCursor, field: String) throws -> Double {
        guard let value = try cursor.consumeNumber() else {
            throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Expected numeric value for ".utf8.count, field.utf8.count)) {
                diagnostic("Expected numeric value for \(field)", location: cursor.currentLocation)
            }
        }
        return value
    }

    private func requireIntNumber(_ cursor: inout TokenCursor, field: String) throws -> Int {
        guard let value = try cursor.consumeIntNumber() else {
            throw try sourceFailure(diagnosticBytes: try PEXParserStorageSize.add("Expected integer value for ".utf8.count, field.utf8.count)) {
                diagnostic("Expected integer value for \(field)", location: cursor.currentLocation)
            }
        }
        return value
    }

    private func sourceFailure(diagnosticBytes: Int,
        _ make: () -> SPEFParserDiagnostic) throws -> any Error {
        guard let resources else { return make() }
        return try resources.sourceFailure(diagnosticBytes: diagnosticBytes, make)
    }

    private func diagnostic(_ message: String, location: SPEFSourceLocation?) -> SPEFParserDiagnostic {
        SPEFParserDiagnostic(severity: .error, message: message, location: location)
    }
}

// MARK: - Token Cursor

struct TokenCursor: Sendable {
    let tokens: [SPEFToken.Located]
    let resources: PEXParserResourceScope?
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

    mutating func advance() throws {
        try resources?.check()
        if index < tokens.count { index += 1 }
    }

    mutating func skipNewlines() throws {
        try resources?.check()
        while index < tokens.count, case .newline = tokens[index].token {
            try resources?.check()
            index += 1
        }
    }

    mutating func skipUntilLineEnd() throws {
        try resources?.check()
        while index < tokens.count {
            try resources?.check()
            switch tokens[index].token {
            case .newline, .endOfFile:
                return
            default:
                index += 1
            }
        }
    }

    mutating func skipToNextKeyword() throws {
        try resources?.check()
        while index < tokens.count {
            try resources?.check()
            if case .keyword(_) = tokens[index].token { return }
            index += 1
        }
    }

    mutating func consumeString() throws -> String? {
        try resources?.check()
        try skipNewlines()
        guard index < tokens.count else { return nil }
        if case .string(let s) = tokens[index].token {
            index += 1
            return s
        }
        return nil
    }

    mutating func consumeIdentifier() throws -> String? {
        try resources?.check()
        try skipNewlines()
        guard index < tokens.count else { return nil }
        guard var value = try consumeIdentifierComponent() else {
            return nil
        }

        while index < tokens.count {
            try resources?.check()
            guard case .colon = tokens[index].token else {
                break
            }
            index += 1
            guard let suffix = try consumeIdentifierComponent() else {
                return nil
            }
            value += ":\(suffix)"
        }

        return value
    }

    mutating func consumeIdentifierOrPunctuation() throws -> String? {
        try resources?.check()
        try skipNewlines()
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

    mutating func consumeNumber() throws -> Double? {
        try resources?.check()
        try skipNewlines()
        guard index < tokens.count else { return nil }
        if case .number(let n) = tokens[index].token {
            index += 1
            return n
        }
        return nil
    }

    mutating func consumeIntNumber() throws -> Int? {
        try resources?.check()
        try skipNewlines()
        guard index < tokens.count else { return nil }
        if case .number(let n) = tokens[index].token {
            guard let value = Int(exactly: n) else {
                return nil
            }
            index += 1
            return value
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

    private mutating func consumeIdentifierComponent() throws -> String? {
        try resources?.check()
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
