import Foundation
import Testing

@testable import PEXCLICore
@testable import PEXEngine

@Suite("correlate-extractor-reports CLI")
struct CorrelateExtractorReportsCommandTests {
    @Test("CLI writes canonical correlation once and refuses overwrite")
    func writesImmutableCanonicalCorrelation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CorrelateExtractorReportsCommandTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeCorrelationFixture(root) }
        let corpusURL = root.appending(path: "corpus.json")
        let primaryURL = root.appending(path: "primary.json")
        let oracleURL = root.appending(path: "oracle.json")
        let outputURL = root.appending(path: "correlation.json")
        try PEXExtractorCorpus(
            corpusID: "corpus",
            cases: [.init(
                caseID: "case",
                coverageTags: ["pex.physical-value"],
                expectedTotalCapacitanceF: 10,
                totalCapacitanceToleranceF: 1
            )]
        ).canonicalData().write(to: corpusURL, options: .atomic)
        try makeReport(backendID: "magic", observed: 10.2)
            .canonicalData().write(to: primaryURL, options: .atomic)
        try makeReport(backendID: "openrcx", observed: 9.8)
            .canonicalData().write(to: oracleURL, options: .atomic)

        let arguments = [
            "--corpus", corpusURL.path(percentEncoded: false),
            "--primary-report", primaryURL.path(percentEncoded: false),
            "--oracle-report", oracleURL.path(percentEncoded: false),
            "--correlation-id", "magic-openrcx",
            "--out", outputURL.path(percentEncoded: false),
        ]
        let command = try CorrelateExtractorReportsCommand(arguments: arguments)
        let correlation = try await command.run()

        #expect(correlation.passed)
        let persisted = try Data(contentsOf: outputURL)
        #expect(try PEXExtractorCorrelation.decodeCanonical(from: persisted) == correlation)
        await #expect(throws: PEXError.self) {
            _ = try await command.run()
        }
    }

    @Test("CLI requires every identity-bearing input")
    func requiresCanonicalInputs() {
        #expect(throws: PEXError.self) {
            _ = try CorrelateExtractorReportsCommand(arguments: [])
        }
    }

    private func makeReport(
        backendID: String,
        observed: Double
    ) -> PEXExternalExtractorCorpusReport {
        PEXExternalExtractorCorpusReport(
            corpusSpec: "corpus.json",
            extractorBackendID: backendID,
            status: "passed",
            summary: .init(
                caseCount: 1,
                passedCaseCount: 1,
                failedCaseCount: 0,
                passRate: 1,
                coverageTagCounts: ["pex.physical-value": 1],
                totalGroundCapF: 0,
                totalCouplingCapF: 0,
                totalCapacitanceF: observed,
                totalResistanceOhm: 0,
                totalNetCount: 1,
                totalElementCount: 1
            ),
            evaluation: .init(
                policy: .init(requiredCoverageTags: ["pex.physical-value"], minimumPassRate: 1),
                failures: []
            ),
            cases: [.init(
                caseID: "case",
                status: "passed",
                coverageTags: ["pex.physical-value"],
                totalCapacitanceF: observed,
                expectedTotalCapacitanceF: 10,
                totalCapacitanceToleranceF: 1,
                netCount: 1,
                elementCount: 1
            )]
        )
    }
}

private func removeCorrelationFixture(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("Failed to remove correlation fixture: \(error)")
    }
}
