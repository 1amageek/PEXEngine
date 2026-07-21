import Foundation
import PEXEngine

struct CorrelateExtractorReportsCommandArguments: Sendable {
    let corpusURL: URL
    let primaryReportURL: URL
    let oracleReportURL: URL
    let outputURL: URL
    let correlationID: String
    let jsonOutput: Bool

    init(arguments: [String]) throws {
        var cursor = PEXCLIArgumentCursor(arguments: arguments)
        var corpusPath: String?
        var primaryReportPath: String?
        var oracleReportPath: String?
        var outputPath: String?
        var correlationID: String?
        var jsonOutput = false

        while let argument = cursor.next() {
            switch argument {
            case "--corpus":
                corpusPath = try cursor.requireValue(for: argument)
            case "--primary-report":
                primaryReportPath = try cursor.requireValue(for: argument)
            case "--oracle-report":
                oracleReportPath = try cursor.requireValue(for: argument)
            case "--out":
                outputPath = try cursor.requireValue(for: argument)
            case "--correlation-id":
                correlationID = try cursor.requireValue(for: argument)
            case "--json":
                jsonOutput = true
            default:
                throw PEXError.invalidInput(
                    "Unknown correlate-extractor-reports argument '\(argument)'"
                )
            }
        }

        self.corpusURL = try Self.requiredURL(corpusPath, option: "--corpus")
        self.primaryReportURL = try Self.requiredURL(primaryReportPath, option: "--primary-report")
        self.oracleReportURL = try Self.requiredURL(oracleReportPath, option: "--oracle-report")
        self.outputURL = try Self.requiredURL(outputPath, option: "--out")
        guard let correlationID,
              !correlationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PEXError.invalidInput("--correlation-id <id> is required")
        }
        self.correlationID = correlationID
        self.jsonOutput = jsonOutput
    }

    private static func requiredURL(_ path: String?, option: String) throws -> URL {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PEXError.invalidInput("\(option) <path> is required")
        }
        return URL(filePath: path)
    }
}
