import Foundation
import PEXEngine

struct ParseCorpusCommandArguments: Sendable {
    let manifestURL: URL
    let fixtureDirectory: URL?
    let outputURL: URL?
    let jsonOutput: Bool

    init(arguments: [String]) throws {
        var builder = ParseCorpusCommandArgumentBuilder()
        try builder.parse(arguments: arguments)

        guard let manifestPath = builder.manifestPath else {
            throw PEXError.invalidInput("--manifest <path> is required for parse-corpus command")
        }

        self.manifestURL = URL(filePath: manifestPath)
        self.fixtureDirectory = builder.fixtureDirectoryPath.map { URL(filePath: $0) }
        self.outputURL = builder.outputPath.map { URL(filePath: $0) }
        self.jsonOutput = builder.jsonOutput
    }
}

private struct ParseCorpusCommandArgumentBuilder: Sendable {
    var manifestPath: String?
    var fixtureDirectoryPath: String?
    var outputPath: String?
    var jsonOutput = false

    mutating func parse(arguments: [String]) throws {
        var cursor = PEXCLIArgumentCursor(arguments: arguments)
        while let argument = cursor.next() {
            switch argument {
            case "--manifest":
                manifestPath = try cursor.requireValue(for: argument)
            case "--fixtures-dir":
                fixtureDirectoryPath = try cursor.requireValue(for: argument)
            case "--out":
                outputPath = try cursor.requireValue(for: argument)
            case "--json":
                jsonOutput = true
            default:
                if argument.hasPrefix("-") {
                    throw PEXError.invalidInput("Unknown parse-corpus argument '\(argument)'")
                }
                guard manifestPath == nil else {
                    throw PEXError.invalidInput("Unexpected parse-corpus positional argument '\(argument)'")
                }
                manifestPath = argument
            }
        }
    }
}
