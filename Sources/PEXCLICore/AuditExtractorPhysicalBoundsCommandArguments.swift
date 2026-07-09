import Foundation
import PEXEngine

struct AuditExtractorPhysicalBoundsCommandArguments: Sendable {
    let reportURL: URL
    let outputURL: URL?
    let auditID: String?
    let jsonOutput: Bool

    init(arguments: [String]) throws {
        var builder = AuditExtractorPhysicalBoundsCommandArgumentBuilder()
        try builder.parse(arguments: arguments)

        guard let reportPath = builder.reportPath else {
            throw PEXError.invalidInput("--report <path> is required for audit-extractor-physical-bounds command")
        }

        self.reportURL = URL(filePath: reportPath)
        self.outputURL = builder.outputPath.map { URL(filePath: $0) }
        self.auditID = builder.auditID
        self.jsonOutput = builder.jsonOutput
    }
}

private struct AuditExtractorPhysicalBoundsCommandArgumentBuilder: Sendable {
    var reportPath: String?
    var outputPath: String?
    var auditID: String?
    var jsonOutput = false

    mutating func parse(arguments: [String]) throws {
        var cursor = PEXCLIArgumentCursor(arguments: arguments)
        while let argument = cursor.next() {
            switch argument {
            case "--report":
                reportPath = try cursor.requireValue(for: argument)
            case "--out":
                outputPath = try cursor.requireValue(for: argument)
            case "--audit-id":
                auditID = try cursor.requireValue(for: argument)
            case "--json":
                jsonOutput = true
            default:
                if argument.hasPrefix("-") {
                    throw PEXError.invalidInput("Unknown audit-extractor-physical-bounds argument '\(argument)'")
                }
                guard reportPath == nil else {
                    throw PEXError.invalidInput("Unexpected audit-extractor-physical-bounds positional argument '\(argument)'")
                }
                reportPath = argument
            }
        }
    }
}
