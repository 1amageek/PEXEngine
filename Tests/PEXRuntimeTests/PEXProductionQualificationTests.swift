import Foundation
import Testing

@testable import PEXRuntime

@Suite("PEX extractor evidence")
struct PEXExtractorEvidenceTests {
    @Test("corpus canonical data preserves deterministic case order")
    func corpusCanonicalOrder() throws {
        let corpus = makeCorpus(caseIDs: ["z", "a"])
        let decoded = try PEXExtractorCorpus.decodeCanonical(from: corpus.canonicalData())

        #expect(decoded.cases.map(\.caseID) == ["a", "z"])
    }

    @Test("empty corpus is structurally invalid")
    func emptyCorpusIsInvalid() {
        #expect(!PEXExtractorCorpus(corpusID: "empty", cases: []).isValid)
    }

    @Test("independent extractor correlation records raw observations")
    func independentCorrelation() {
        #expect(makeCorrelation().passed)
    }

    @Test("one implementation cannot act as its own oracle")
    func selfOracleIsInvalid() {
        let correlation = PEXExtractorCorrelation(
            correlationID: "correlation",
            primaryBackendID: "same",
            oracleBackendID: "same",
            corpusDigest: digest("a"),
            primaryReportDigest: digest("b"),
            oracleReportDigest: digest("c"),
            cases: [makeCaseComparison()]
        )

        #expect(!correlation.isStructurallyValid)
    }

    @Test("metric comparison reports tolerance mismatch without authorizing release")
    func metricToleranceMismatch() {
        let comparison = PEXExtractorCorrelation.MetricComparison(
            metricID: "totalCapacitanceF",
            primaryObserved: 12,
            oracleObserved: 10,
            expected: 10,
            absoluteTolerance: 1
        )

        #expect(!comparison.passed)
    }

    @Test("correlation canonical round trip is exact")
    func correlationCanonicalRoundTrip() throws {
        let correlation = makeCorrelation()
        let data = try correlation.canonicalData()

        #expect(try PEXExtractorCorrelation.decodeCanonical(from: data) == correlation)
    }

    @Test("external report rejects non-canonical JSON")
    func reportRejectsNonCanonicalJSON() throws {
        let report = makeReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        #expect(throws: PEXEvidenceValidationError.self) {
            _ = try PEXExternalExtractorCorpusReport.decodeCanonical(from: encoder.encode(report))
        }
    }

    private func makeCorpus(caseIDs: [String] = ["inverter"]) -> PEXExtractorCorpus {
        PEXExtractorCorpus(
            corpusID: "extractor-corpus",
            cases: caseIDs.map { caseID in
                PEXExtractorCorpus.Case(
                    caseID: caseID,
                    topCell: "INV",
                    corner: "tt",
                    coverageTags: ["pex.physical-value"],
                    expectedTotalCapacitanceF: 10,
                    totalCapacitanceToleranceF: 1
                )
            }
        )
    }

    private func makeCorrelation() -> PEXExtractorCorrelation {
        PEXExtractorCorrelation(
            correlationID: "correlation",
            primaryBackendID: "primary",
            oracleBackendID: "oracle",
            corpusDigest: digest("a"),
            primaryReportDigest: digest("b"),
            oracleReportDigest: digest("c"),
            cases: [makeCaseComparison()]
        )
    }

    private func makeCaseComparison() -> PEXExtractorCorrelation.CaseComparison {
        PEXExtractorCorrelation.CaseComparison(
            caseID: "inverter",
            coverageTags: ["pex.physical-value"],
            metrics: [PEXExtractorCorrelation.MetricComparison(
                metricID: "totalCapacitanceF",
                primaryObserved: 10,
                oracleObserved: 10,
                expected: 10,
                absoluteTolerance: 1
            )]
        )
    }

    private func makeReport() -> PEXExternalExtractorCorpusReport {
        PEXExternalExtractorCorpusReport(
            corpusSpec: "corpus.json",
            extractorBackendID: "primary",
            status: "passed",
            summary: .init(
                caseCount: 1,
                passedCaseCount: 1,
                failedCaseCount: 0,
                passRate: 1,
                coverageTagCounts: ["pex.physical-value": 1],
                totalGroundCapF: 0,
                totalCouplingCapF: 0,
                totalCapacitanceF: 10,
                totalResistanceOhm: 0,
                totalNetCount: 1,
                totalElementCount: 1
            ),
            evaluation: .init(
                policy: .init(requiredCoverageTags: ["pex.physical-value"], minimumPassRate: 1),
                failures: []
            ),
            cases: [.init(
                caseID: "inverter",
                status: "passed",
                coverageTags: ["pex.physical-value"],
                totalCapacitanceF: 10,
                netCount: 1,
                elementCount: 1
            )]
        )
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}
