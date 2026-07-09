import Foundation
import PEXEngine

public struct MetricRecoveryObjectiveCommand: Sendable {
    public let summaryURL: URL
    public let comparisonURL: URL?
    public let metricReportURL: URL?
    public let outputURL: URL?
    public let layoutPath: String?
    public let sourceNetlistPath: String?
    public let technologyPath: String?
    public let problemID: String?
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        let parsed = try MetricRecoveryObjectiveCommandArguments(arguments: arguments)
        self.summaryURL = parsed.summaryURL
        self.comparisonURL = parsed.comparisonURL
        self.metricReportURL = parsed.metricReportURL
        self.outputURL = parsed.outputURL
        self.layoutPath = parsed.layoutPath
        self.sourceNetlistPath = parsed.sourceNetlistPath
        self.technologyPath = parsed.technologyPath
        self.problemID = parsed.problemID
        self.jsonOutput = parsed.jsonOutput
    }

    public func run() async throws {
        let problem = try buildProblem()
        if let outputURL {
            try write(problem, to: outputURL)
        }

        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(problem)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("PEX metric recovery objective: \(problem.status)")
            print("Problem ID: \(problem.problemID)")
            print("Objectives: \(problem.summary.objectiveCount)")
            print("Hotspots: \(problem.summary.hotspotCount)")
            print("Diagnostics: \(problem.summary.diagnosticCount)")
            if let outputURL {
                print("Output: \(outputURL.path(percentEncoded: false))")
            }
        }
    }

    public func buildProblem() throws -> PEXMetricRecoveryPlanningProblem {
        let summary = try decode(
            PEXRunSummaryReport.self,
            from: summaryURL,
            role: "PEX summary"
        )
        let comparison = try comparisonURL.map {
            try decode(PEXIRComparisonReport.self, from: $0, role: "PEX IR comparison report")
        }
        let metricReport = try metricReportURL.map {
            try decode(PEXMetricRecoveryMetricReport.self, from: $0, role: "post-layout metric report")
        }

        return try PEXMetricRecoveryObjectiveBuilder().build(
            summary: summary,
            summaryPath: summaryURL.path(percentEncoded: false),
            comparison: comparison,
            comparisonPath: comparisonURL?.path(percentEncoded: false),
            metricReport: metricReport,
            metricReportPath: metricReportURL?.path(percentEncoded: false),
            layoutPath: layoutPath,
            sourceNetlistPath: sourceNetlistPath,
            technologyPath: technologyPath,
            problemID: problemID
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL, role: String) throws -> T {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to read \(role) at \(url.path(percentEncoded: false))",
                underlying: error
            )
        }

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw PEXError.parseFailed(
                cornerID: "pex-metric-recovery",
                message: "Failed to decode \(role)",
                underlying: error
            )
        }
    }

    private func write(_ problem: PEXMetricRecoveryPlanningProblem, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(problem)
            try data.write(to: url, options: .atomic)
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to write PEX metric recovery objective to \(url.path(percentEncoded: false))",
                underlying: error
            )
        }
    }
}
