import Foundation
import PEXEngine

struct MetricRecoveryObjectiveCommandArguments: Sendable {
    let summaryURL: URL
    let comparisonURL: URL?
    let metricReportURL: URL?
    let outputURL: URL?
    let layoutPath: String?
    let sourceNetlistPath: String?
    let technologyPath: String?
    let problemID: String?
    let jsonOutput: Bool

    init(arguments: [String]) throws {
        let builder = try MetricRecoveryObjectiveCommandArgumentBuilder(arguments: arguments).build()

        guard let summaryPath = builder.summaryPath else {
            throw PEXError.invalidInput("--summary <path> is required for metric-recovery-objective command")
        }

        self.summaryURL = URL(filePath: summaryPath)
        self.comparisonURL = builder.comparisonPath.map { URL(filePath: $0) }
        self.metricReportURL = builder.metricReportPath.map { URL(filePath: $0) }
        self.outputURL = builder.outputPath.map { URL(filePath: $0) }
        self.layoutPath = builder.layoutPath
        self.sourceNetlistPath = builder.sourceNetlistPath
        self.technologyPath = builder.technologyPath
        self.problemID = builder.problemID
        self.jsonOutput = builder.jsonOutput
    }
}

private struct MetricRecoveryObjectiveCommandArgumentBuilder: Sendable {
    var summaryPath: String?
    var comparisonPath: String?
    var metricReportPath: String?
    var outputPath: String?
    var layoutPath: String?
    var sourceNetlistPath: String?
    var technologyPath: String?
    var problemID: String?
    var jsonOutput: Bool

    init(arguments: [String]) throws {
        var cursor = PEXCLIArgumentCursor(arguments: arguments)
        var summaryPath: String?
        var comparisonPath: String?
        var metricReportPath: String?
        var outputPath: String?
        var layoutPath: String?
        var sourceNetlistPath: String?
        var technologyPath: String?
        var problemID: String?
        var jsonOutput = false

        while let argument = cursor.next() {
            switch argument {
            case "--summary":
                summaryPath = try cursor.requireValue(for: argument)
            case "--comparison", "--ir-comparison":
                comparisonPath = try cursor.requireValue(for: argument)
            case "--metric-report", "--post-layout-metric-report":
                metricReportPath = try cursor.requireValue(for: argument)
            case "--out":
                outputPath = try cursor.requireValue(for: argument)
            case "--layout":
                layoutPath = try cursor.requireValue(for: argument)
            case "--source-netlist", "--netlist":
                sourceNetlistPath = try cursor.requireValue(for: argument)
            case "--technology":
                technologyPath = try cursor.requireValue(for: argument)
            case "--problem-id":
                problemID = try cursor.requireValue(for: argument)
            case "--json":
                jsonOutput = true
            default:
                if argument.hasPrefix("-") {
                    throw PEXError.invalidInput("Unknown metric-recovery-objective argument '\(argument)'")
                }
                guard summaryPath == nil else {
                    throw PEXError.invalidInput(
                        "Unexpected metric-recovery-objective positional argument '\(argument)'"
                    )
                }
                summaryPath = argument
            }
        }

        self.summaryPath = summaryPath
        self.comparisonPath = comparisonPath
        self.metricReportPath = metricReportPath
        self.outputPath = outputPath
        self.layoutPath = layoutPath
        self.sourceNetlistPath = sourceNetlistPath
        self.technologyPath = technologyPath
        self.problemID = problemID
        self.jsonOutput = jsonOutput
    }

    func build() -> Self {
        self
    }
}
