import PEXEngine

struct WriteSPEFCommandArguments: Sendable {
    let inputPath: String
    let outputPath: String
    let jsonOutput: Bool
    let reportPath: String?
    let roundTrip: Bool
    let roundTripCornerID: String?
    let designName: String?
    let date: String?
    let vendor: String?
    let program: String?

    init(
        inputPath: String,
        outputPath: String,
        jsonOutput: Bool,
        reportPath: String?,
        roundTrip: Bool,
        roundTripCornerID: String?,
        designName: String?,
        date: String?,
        vendor: String?,
        program: String?
    ) {
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.jsonOutput = jsonOutput
        self.reportPath = reportPath
        self.roundTrip = roundTrip
        self.roundTripCornerID = roundTripCornerID
        self.designName = designName
        self.date = date
        self.vendor = vendor
        self.program = program
    }

    init(arguments: [String]) throws {
        var builder = WriteSPEFCommandArgumentBuilder()
        var cursor = WriteSPEFArgumentCursor(arguments: arguments)
        while let argument = cursor.next() {
            try builder.apply(argument, cursor: &cursor)
        }
        self = try builder.build()
    }
}

private struct WriteSPEFCommandArgumentBuilder {
    var inputPath: String?
    var outputPath: String?
    var jsonOutput = false
    var reportPath: String?
    var roundTrip = false
    var roundTripCornerID: String?
    var designName: String?
    var date: String?
    var vendor: String?
    var program: String?

    mutating func apply(_ argument: String, cursor: inout WriteSPEFArgumentCursor) throws {
        switch argument {
        case "--input":
            inputPath = try cursor.requireValue(for: "--input")
        case "--output", "--out":
            outputPath = try cursor.requireValue(for: argument)
        case "--report":
            reportPath = try cursor.requireValue(for: "--report")
        case "--round-trip":
            roundTrip = true
        case "--round-trip-corner":
            roundTripCornerID = try cursor.requireValue(for: "--round-trip-corner")
        case "--design-name":
            designName = try cursor.requireValue(for: "--design-name")
        case "--date":
            date = try cursor.requireValue(for: "--date")
        case "--vendor":
            vendor = try cursor.requireValue(for: "--vendor")
        case "--program":
            program = try cursor.requireValue(for: "--program")
        case "--json":
            jsonOutput = true
        default:
            try applyPositional(argument)
        }
    }

    func build() throws -> WriteSPEFCommandArguments {
        guard let inputPath else {
            throw PEXError.invalidInput("--input <path> is required for write-spef command")
        }
        guard let outputPath else {
            throw PEXError.invalidInput("--output <path> is required for write-spef command")
        }
        return WriteSPEFCommandArguments(
            inputPath: inputPath,
            outputPath: outputPath,
            jsonOutput: jsonOutput,
            reportPath: reportPath,
            roundTrip: roundTrip,
            roundTripCornerID: roundTripCornerID,
            designName: designName,
            date: date,
            vendor: vendor,
            program: program
        )
    }

    private mutating func applyPositional(_ argument: String) throws {
        if argument.hasPrefix("-") {
            throw PEXError.invalidInput("Unknown write-spef argument '\(argument)'")
        }
        if inputPath == nil {
            inputPath = argument
            return
        }
        if outputPath == nil {
            outputPath = argument
            return
        }
        throw PEXError.invalidInput("Unexpected write-spef positional argument '\(argument)'")
    }
}

private struct WriteSPEFArgumentCursor {
    private let arguments: [String]
    private var index = 0

    init(arguments: [String]) {
        self.arguments = arguments
    }

    mutating func next() -> String? {
        guard index < arguments.count else { return nil }
        let value = arguments[index]
        index += 1
        return value
    }

    mutating func requireValue(for option: String) throws -> String {
        guard let value = next() else {
            throw PEXError.invalidInput("\(option) requires a value")
        }
        guard !value.isEmpty, !value.hasPrefix("-") else {
            throw PEXError.invalidInput("\(option) requires a value")
        }
        return value
    }
}
