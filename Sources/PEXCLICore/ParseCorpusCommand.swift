import Foundation
import PEXEngine

public struct ParseCorpusCommand: Sendable {
    public let manifestURL: URL
    public let fixtureDirectory: URL?
    public let outputURL: URL?
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        let parsed = try ParseCorpusCommandArguments(arguments: arguments)
        self.manifestURL = parsed.manifestURL
        self.fixtureDirectory = parsed.fixtureDirectory
        self.outputURL = parsed.outputURL
        self.jsonOutput = parsed.jsonOutput
    }

    @discardableResult
    public func run() async throws -> Bool {
        let report = try buildReport()
        if let outputURL {
            try writeReport(report, to: outputURL)
        }

        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(report)
            print(String(data: jsonData, encoding: .utf8) ?? "{}")
        } else {
            print("Status: \(report.status)")
            print("Cases: \(report.summary.passedCaseCount)/\(report.summary.caseCount) passed")
            print("Coverage tags: \(report.summary.coverageTagCounts.count)")
            if let outputURL {
                print("Report: \(outputURL.path(percentEncoded: false))")
            }
            if !report.qualification.failures.isEmpty {
                print("Failures:")
                for failure in report.qualification.failures {
                    print("  \(failure.code): \(failure.message)")
                }
            }
        }
        return report.qualification.qualified
    }

    public func buildReport() throws -> SPEFCorpus.Report {
        try SPEFCorpusRunner().run(
            manifestURL: manifestURL,
            fixtureDirectory: fixtureDirectory
        )
    }

    private func writeReport(_ report: SPEFCorpus.Report, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: url, options: .atomic)
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to write SPEF corpus report to \(url.path(percentEncoded: false))",
                underlying: error
            )
        }
    }
}
