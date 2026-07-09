import Foundation
import PEXEngine

struct EvidenceFromCorpusReportCommandArguments: Sendable {
    let reportURL: URL
    let evidenceID: String?
    let checkedAt: Date
    let jsonOutput: Bool

    init(arguments: [String], now: Date) throws {
        var builder = EvidenceFromCorpusReportCommandArgumentBuilder(checkedAt: now)
        try builder.parse(arguments: arguments)

        guard let reportPath = builder.reportPath else {
            throw PEXError.invalidInput("--report <path> is required for evidence-from-corpus-report command")
        }

        self.reportURL = URL(filePath: reportPath)
        self.evidenceID = builder.evidenceID
        self.checkedAt = builder.checkedAt
        self.jsonOutput = builder.jsonOutput
    }
}

private struct EvidenceFromCorpusReportCommandArgumentBuilder: Sendable {
    var reportPath: String?
    var evidenceID: String?
    var checkedAt: Date
    var jsonOutput = false

    mutating func parse(arguments: [String]) throws {
        var cursor = PEXCLIArgumentCursor(arguments: arguments)
        while let argument = cursor.next() {
            switch argument {
            case "--report", "--evidence-from-corpus-report":
                reportPath = try cursor.requireValue(for: argument)
            case "--evidence-id":
                evidenceID = try cursor.requireValue(for: argument)
            case "--checked-at":
                let value = try cursor.requireValue(for: argument)
                checkedAt = try Self.iso8601Date(argument: argument, value: value)
            case "--json":
                jsonOutput = true
            default:
                if argument.hasPrefix("-") {
                    throw PEXError.invalidInput("Unknown evidence-from-corpus-report argument '\(argument)'")
                }
                guard reportPath == nil else {
                    throw PEXError.invalidInput("Unexpected evidence-from-corpus-report positional argument '\(argument)'")
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
