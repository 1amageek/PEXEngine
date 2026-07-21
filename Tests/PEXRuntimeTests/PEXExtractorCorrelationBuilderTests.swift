import CryptoKit
import Foundation
import Testing

@testable import PEXRuntime

@Suite("PEX extractor correlation builder")
struct PEXExtractorCorrelationBuilderTests {
    @Test("canonical reports from distinct backend IDs produce a passing correlation")
    func buildsPassingCorrelation() throws {
        let inputs = try makeInputs()

        let correlation = try PEXExtractorCorrelationBuilder().build(
            correlationID: "magic-openrcx",
            corpusData: inputs.corpusData,
            primaryReportData: inputs.primaryReportData,
            oracleReportData: inputs.oracleReportData
        )

        #expect(correlation.passed)
        #expect(correlation.primaryBackendID == "magic")
        #expect(correlation.oracleBackendID == "openrcx")
        #expect(correlation.corpusDigest == digest(inputs.corpusData))
        #expect(correlation.primaryReportDigest == digest(inputs.primaryReportData))
        #expect(correlation.oracleReportDigest == digest(inputs.oracleReportData))
    }

    @Test("a backend cannot be its own oracle")
    func rejectsSelfOracle() throws {
        let inputs = try makeInputs(oracleBackendID: "magic")

        #expect(throws: PEXExtractorCorrelationBuildError.identicalBackend("magic")) {
            _ = try PEXExtractorCorrelationBuilder().build(
                correlationID: "self",
                corpusData: inputs.corpusData,
                primaryReportData: inputs.primaryReportData,
                oracleReportData: inputs.oracleReportData
            )
        }
    }

    @Test("correlation identity must be a stable non-empty token")
    func rejectsInvalidCorrelationIdentity() throws {
        let inputs = try makeInputs()

        #expect(throws: PEXExtractorCorrelationBuildError.invalidCorrelationID(" ")) {
            _ = try PEXExtractorCorrelationBuilder().build(
                correlationID: " ",
                corpusData: inputs.corpusData,
                primaryReportData: inputs.primaryReportData,
                oracleReportData: inputs.oracleReportData
            )
        }
    }

    @Test("report case sets must exactly match the canonical corpus")
    func rejectsCaseSetMismatch() throws {
        let inputs = try makeInputs(oracleCaseID: "different")

        #expect(throws: PEXExtractorCorrelationBuildError.caseSetMismatch) {
            _ = try PEXExtractorCorrelationBuilder().build(
                correlationID: "mismatch",
                corpusData: inputs.corpusData,
                primaryReportData: inputs.primaryReportData,
                oracleReportData: inputs.oracleReportData
            )
        }
    }

    @Test("report expectations cannot diverge from the canonical corpus")
    func rejectsExpectationMismatch() throws {
        let inputs = try makeInputs(oracleExpectedCapacitance: 11)

        #expect(throws: PEXExtractorCorrelationBuildError.expectedMetricMismatch(
            caseID: "inverter",
            metricID: "totalCapacitanceF"
        )) {
            _ = try PEXExtractorCorrelationBuilder().build(
                correlationID: "mismatch",
                corpusData: inputs.corpusData,
                primaryReportData: inputs.primaryReportData,
                oracleReportData: inputs.oracleReportData
            )
        }
    }

    private func makeInputs(
        oracleBackendID: String = "openrcx",
        oracleCaseID: String = "inverter",
        oracleExpectedCapacitance: Double = 10
    ) throws -> CorrelationInputs {
        let corpus = PEXExtractorCorpus(
            corpusID: "physical-correlation",
            cases: [PEXExtractorCorpus.Case(
                caseID: "inverter",
                topCell: "INV",
                corner: "tt",
                coverageTags: ["pex.physical-value"],
                expectedTotalCapacitanceF: 10,
                totalCapacitanceToleranceF: 1
            )]
        )
        let primary = makeReport(
            backendID: "magic",
            caseID: "inverter",
            observedCapacitance: 10.2,
            expectedCapacitance: 10
        )
        let oracle = makeReport(
            backendID: oracleBackendID,
            caseID: oracleCaseID,
            observedCapacitance: 9.8,
            expectedCapacitance: oracleExpectedCapacitance
        )
        return CorrelationInputs(
            corpusData: try corpus.canonicalData(),
            primaryReportData: try primary.canonicalData(),
            oracleReportData: try oracle.canonicalData()
        )
    }

    private func makeReport(
        backendID: String,
        caseID: String,
        observedCapacitance: Double,
        expectedCapacitance: Double
    ) -> PEXExternalExtractorCorpusReport {
        PEXExternalExtractorCorpusReport(
            corpusSpec: "physical-correlation.json",
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
                totalCapacitanceF: observedCapacitance,
                totalResistanceOhm: 0,
                totalNetCount: 1,
                totalElementCount: 1
            ),
            evaluation: .init(
                policy: .init(requiredCoverageTags: ["pex.physical-value"], minimumPassRate: 1),
                failures: []
            ),
            cases: [.init(
                caseID: caseID,
                status: "passed",
                topCell: "INV",
                corner: "tt",
                coverageTags: ["pex.physical-value"],
                totalCapacitanceF: observedCapacitance,
                expectedTotalCapacitanceF: expectedCapacitance,
                totalCapacitanceToleranceF: 1,
                netCount: 1,
                elementCount: 1
            )]
        )
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CorrelationInputs {
    let corpusData: Data
    let primaryReportData: Data
    let oracleReportData: Data
}
