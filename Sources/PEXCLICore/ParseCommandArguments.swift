import PEXEngine

struct ParseCommandArguments: Sendable {
    let inputPath: String
    let format: PEXOutputFormat
    let cornerID: String
    let topSubckt: String?
    let jsonOutput: Bool
    let reportOutput: Bool

    init(arguments: [String]) throws {
        var builder = ParseCommandArgumentBuilder()
        var cursor = PEXCLIArgumentCursor(arguments: arguments)
        while let argument = cursor.next() {
            try builder.apply(argument, cursor: &cursor)
        }
        self = try builder.build()
    }

    init(
        inputPath: String,
        format: PEXOutputFormat,
        cornerID: String,
        topSubckt: String?,
        jsonOutput: Bool,
        reportOutput: Bool
    ) {
        self.inputPath = inputPath
        self.format = format
        self.cornerID = cornerID
        self.topSubckt = topSubckt
        self.jsonOutput = jsonOutput
        self.reportOutput = reportOutput
    }
}

private struct ParseCommandArgumentBuilder {
    var inputPath: String?
    var formatName = "spef"
    var cornerID = "default"
    var topSubckt: String?
    var jsonOutput = false
    var reportOutput = false

    mutating func apply(_ argument: String, cursor: inout PEXCLIArgumentCursor) throws {
        switch argument {
        case "--input":
            inputPath = try cursor.requireValue(for: "--input")
        case "--format":
            formatName = try cursor.requireValue(for: "--format")
        case "--corner":
            cornerID = try cursor.requireValue(for: "--corner")
        case "--top-subckt":
            topSubckt = try cursor.requireValue(for: "--top-subckt")
        case "--report":
            reportOutput = true
        case "--json":
            jsonOutput = true
        default:
            try applyPositional(argument)
        }
    }

    func build() throws -> ParseCommandArguments {
        guard let inputPath else {
            throw PEXError.invalidInput("Input file path is required")
        }
        guard let format = PEXOutputFormat(rawValue: formatName),
              [.spef, .dspf, .spice].contains(format) else {
            throw PEXError.invalidInput("Unsupported format '\(formatName)'. Supported: spef, dspf, spice")
        }
        return ParseCommandArguments(
            inputPath: inputPath,
            format: format,
            cornerID: cornerID,
            topSubckt: topSubckt,
            jsonOutput: jsonOutput,
            reportOutput: reportOutput
        )
    }

    private mutating func applyPositional(_ argument: String) throws {
        if argument.hasPrefix("-") {
            throw PEXError.invalidInput("Unknown parse argument '\(argument)'")
        }
        if inputPath == nil {
            inputPath = argument
            return
        }
        throw PEXError.invalidInput("Unexpected parse positional argument '\(argument)'")
    }
}
