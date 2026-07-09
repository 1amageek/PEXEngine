import PEXEngine

struct CompareIRCommandArguments: Sendable {
    let baselinePath: String
    let candidatePath: String
    let reportPath: String?
    let jsonOutput: Bool
    let equivalenceMode: Bool
    let thresholds: PEXIRComparisonThresholds

    init(arguments: [String]) throws {
        var builder = CompareIRCommandArgumentBuilder()
        var cursor = PEXCLIArgumentCursor(arguments: arguments)
        while let argument = cursor.next() {
            try builder.apply(argument, cursor: &cursor)
        }
        self = try builder.build()
    }

    init(
        baselinePath: String,
        candidatePath: String,
        reportPath: String?,
        jsonOutput: Bool,
        equivalenceMode: Bool,
        thresholds: PEXIRComparisonThresholds
    ) {
        self.baselinePath = baselinePath
        self.candidatePath = candidatePath
        self.reportPath = reportPath
        self.jsonOutput = jsonOutput
        self.equivalenceMode = equivalenceMode
        self.thresholds = thresholds
    }
}

private struct CompareIRCommandArgumentBuilder {
    var baselinePath: String?
    var candidatePath: String?
    var reportPath: String?
    var jsonOutput = false
    var equivalenceMode = false
    var maxCapDeltaF: Double?
    var maxCapRelativeDelta: Double?
    var maxResistanceDeltaOhm: Double?
    var maxResistanceRelativeDelta: Double?
    var equivalenceValueTolerance: Double?
    var allowNetSetChanges = false

    mutating func apply(_ argument: String, cursor: inout PEXCLIArgumentCursor) throws {
        switch argument {
        case "--baseline":
            baselinePath = try cursor.requireValue(for: "--baseline")
        case "--candidate":
            candidatePath = try cursor.requireValue(for: "--candidate")
        case "--report", "--out":
            reportPath = try cursor.requireValue(for: argument)
        case "--cap-abs-tolerance-f":
            maxCapDeltaF = try parseNonNegativeDouble(option: argument, cursor: &cursor)
        case "--cap-rel-tolerance":
            maxCapRelativeDelta = try parseNonNegativeDouble(option: argument, cursor: &cursor)
        case "--res-abs-tolerance-ohm":
            maxResistanceDeltaOhm = try parseNonNegativeDouble(option: argument, cursor: &cursor)
        case "--res-rel-tolerance":
            maxResistanceRelativeDelta = try parseNonNegativeDouble(option: argument, cursor: &cursor)
        case "--value-abs-tolerance":
            equivalenceValueTolerance = try parseNonNegativeDouble(option: argument, cursor: &cursor)
        case "--allow-net-set-changes":
            allowNetSetChanges = true
        case "--equivalence":
            equivalenceMode = true
        case "--json":
            jsonOutput = true
        default:
            try applyPositional(argument)
        }
    }

    func build() throws -> CompareIRCommandArguments {
        guard let baselinePath else {
            throw PEXError.invalidInput("--baseline <path> is required for compare-ir command")
        }
        guard let candidatePath else {
            throw PEXError.invalidInput("--candidate <path> is required for compare-ir command")
        }
        return CompareIRCommandArguments(
            baselinePath: baselinePath,
            candidatePath: candidatePath,
            reportPath: reportPath,
            jsonOutput: jsonOutput,
            equivalenceMode: equivalenceMode,
            thresholds: PEXIRComparisonThresholds(
                maxCapDeltaF: maxCapDeltaF,
                maxCapRelativeDelta: maxCapRelativeDelta,
                maxResistanceDeltaOhm: maxResistanceDeltaOhm,
                maxResistanceRelativeDelta: maxResistanceRelativeDelta,
                equivalenceValueTolerance: equivalenceValueTolerance,
                allowNetSetChanges: allowNetSetChanges
            )
        )
    }

    private mutating func applyPositional(_ argument: String) throws {
        if argument.hasPrefix("-") {
            throw PEXError.invalidInput("Unknown compare-ir argument '\(argument)'")
        }
        if baselinePath == nil {
            baselinePath = argument
            return
        }
        if candidatePath == nil {
            candidatePath = argument
            return
        }
        throw PEXError.invalidInput("Unexpected compare-ir positional argument '\(argument)'")
    }

    private func parseNonNegativeDouble(option: String, cursor: inout PEXCLIArgumentCursor) throws -> Double {
        let rawValue = try cursor.requireValue(for: option)
        guard let value = Double(rawValue), value >= 0 else {
            throw PEXError.invalidInput("\(option) requires a non-negative numeric value")
        }
        return value
    }
}
