import Foundation
import PEXEngine

struct ObservationFromCorpusReportCommandArguments: Sendable {
    let reportURL: URL
    let recordID: String?
    let observedAt: Date
    let jsonOutput: Bool

    init(arguments: [String], now: Date) throws {
        var builder = ObservationFromCorpusReportCommandArgumentBuilder(observedAt: now)
        try builder.parse(arguments: arguments)

        guard let reportPath = builder.reportPath else {
            throw PEXError.invalidInput("--report <path> is required for observation-from-corpus-report command")
        }

        self.reportURL = URL(filePath: reportPath)
        self.recordID = builder.recordID
        self.observedAt = builder.observedAt
        self.jsonOutput = builder.jsonOutput
    }
}

private struct ObservationFromCorpusReportCommandArgumentBuilder: Sendable {
    var reportPath: String?
    var recordID: String?
    var observedAt: Date
    var jsonOutput = false

    mutating func parse(arguments: [String]) throws {
        var cursor = PEXCLIArgumentCursor(arguments: arguments)
        while let argument = cursor.next() {
            switch argument {
            case "--report", "--observation-from-corpus-report":
                reportPath = try cursor.requireValue(for: argument)
            case "--record-id":
                recordID = try cursor.requireValue(for: argument)
            case "--observed-at":
                let value = try cursor.requireValue(for: argument)
                observedAt = try Self.iso8601Date(argument: argument, value: value)
            case "--json":
                jsonOutput = true
            default:
                if argument.hasPrefix("-") {
                    throw PEXError.invalidInput("Unknown observation-from-corpus-report argument '\(argument)'")
                }
                guard reportPath == nil else {
                    throw PEXError.invalidInput("Unexpected observation-from-corpus-report positional argument '\(argument)'")
                }
                reportPath = argument
            }
        }
    }

    private static func iso8601Date(argument: String, value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return date
        }
        throw PEXError.invalidInput("\(argument) must be an ISO 8601 timestamp")
    }
}
