import Foundation
import PEXEngine

struct EvidencePacketFromCorpusReportCommandArguments: Sendable {
    let reportURL: URL
    let outputURL: URL?
    let packetID: String?
    let artifactRootURL: URL?
    let jsonOutput: Bool

    init(arguments: [String]) throws {
        var builder = EvidencePacketFromCorpusReportCommandArgumentBuilder()
        try builder.parse(arguments: arguments)

        guard let reportPath = builder.reportPath else {
            throw PEXError.invalidInput("--report <path> is required for evidence-packet-from-corpus-report command")
        }

        self.reportURL = URL(filePath: reportPath)
        self.outputURL = builder.outputPath.map { URL(filePath: $0) }
        self.packetID = builder.packetID
        self.artifactRootURL = builder.artifactRootPath.map { URL(filePath: $0) }
        self.jsonOutput = builder.jsonOutput
    }
}

private struct EvidencePacketFromCorpusReportCommandArgumentBuilder: Sendable {
    var reportPath: String?
    var outputPath: String?
    var packetID: String?
    var artifactRootPath: String?
    var jsonOutput = false

    mutating func parse(arguments: [String]) throws {
        var cursor = PEXCLIArgumentCursor(arguments: arguments)
        while let argument = cursor.next() {
            switch argument {
            case "--report":
                reportPath = try cursor.requireValue(for: argument)
            case "--out":
                outputPath = try cursor.requireValue(for: argument)
            case "--packet-id":
                packetID = try cursor.requireValue(for: argument)
            case "--artifact-root":
                artifactRootPath = try cursor.requireValue(for: argument)
            case "--json":
                jsonOutput = true
            default:
                if argument.hasPrefix("-") {
                    throw PEXError.invalidInput("Unknown evidence-packet-from-corpus-report argument '\(argument)'")
                }
                guard reportPath == nil else {
                    throw PEXError.invalidInput("Unexpected evidence-packet-from-corpus-report positional argument '\(argument)'")
                }
                reportPath = argument
            }
        }
    }
}
