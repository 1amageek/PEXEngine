import CryptoKit
import Foundation

public struct PEXExtractorCorrelationBuilder: Sendable {
    public init() {}

    public func build(
        correlationID: String,
        corpusData: Data,
        primaryReportData: Data,
        oracleReportData: Data
    ) throws -> PEXExtractorCorrelation {
        let normalizedCorrelationID = correlationID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalizedCorrelationID == correlationID,
              !normalizedCorrelationID.isEmpty,
              !correlationID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PEXExtractorCorrelationBuildError.invalidCorrelationID(correlationID)
        }
        let corpus = try PEXExtractorCorpus.decodeCanonical(from: corpusData)
        let primary = try PEXExternalExtractorCorpusReport.decodeCanonical(from: primaryReportData)
        let oracle = try PEXExternalExtractorCorpusReport.decodeCanonical(from: oracleReportData)
        guard primary.extractorBackendID != oracle.extractorBackendID else {
            throw PEXExtractorCorrelationBuildError.identicalBackend(primary.extractorBackendID)
        }
        guard corpusSpec(primary.corpusSpec, identifies: corpus.corpusID),
              corpusSpec(oracle.corpusSpec, identifies: corpus.corpusID) else {
            throw PEXExtractorCorrelationBuildError.invalidReport(
                backendID: "\(primary.extractorBackendID),\(oracle.extractorBackendID)",
                reason: "corpusSpec does not identify the supplied canonical corpus"
            )
        }
        try validate(report: primary, corpus: corpus)
        try validate(report: oracle, corpus: corpus)

        let primaryCases = Dictionary(uniqueKeysWithValues: primary.cases.map { ($0.caseID, $0) })
        let oracleCases = Dictionary(uniqueKeysWithValues: oracle.cases.map { ($0.caseID, $0) })
        guard Set(primaryCases.keys) == Set(oracleCases.keys) else {
            throw PEXExtractorCorrelationBuildError.caseSetMismatch
        }
        let comparisons = try primaryCases.keys.sorted().map { caseID in
            guard let primaryCase = primaryCases[caseID], let oracleCase = oracleCases[caseID] else {
                throw PEXExtractorCorrelationBuildError.caseSetMismatch
            }
            return try compare(
                primaryCase,
                oracleCase,
                corpusCase: corpus.cases.first { $0.caseID == caseID },
                primaryBackendID: primary.extractorBackendID,
                oracleBackendID: oracle.extractorBackendID
            )
        }
        return PEXExtractorCorrelation(
            correlationID: normalizedCorrelationID,
            primaryBackendID: primary.extractorBackendID,
            oracleBackendID: oracle.extractorBackendID,
            corpusDigest: digest(corpusData),
            primaryReportDigest: digest(primaryReportData),
            oracleReportDigest: digest(oracleReportData),
            cases: comparisons
        )
    }

    private func validate(
        report: PEXExternalExtractorCorpusReport,
        corpus: PEXExtractorCorpus
    ) throws {
        let backendID = report.extractorBackendID
        let normalizedBackendID = backendID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard report.schemaVersion == PEXExternalExtractorCorpusReport.currentSchemaVersion,
              normalizedBackendID == backendID,
              !normalizedBackendID.isEmpty,
              !backendID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw PEXExtractorCorrelationBuildError.invalidReport(
                backendID: backendID,
                reason: "schema version or backend identifier is invalid"
            )
        }
        guard report.status == "passed", report.evaluation.passed else {
            throw PEXExtractorCorrelationBuildError.reportNotPassed(
                backendID: backendID
            )
        }
        guard report.cases.count == corpus.cases.count,
              Set(report.cases.map(\.caseID)).count == report.cases.count,
              report.summary.caseCount == report.cases.count,
              report.summary.passedCaseCount == report.cases.count,
              report.summary.failedCaseCount == 0,
              report.summary.passRate == 1 else {
            throw PEXExtractorCorrelationBuildError.invalidReport(
                backendID: backendID,
                reason: "case summary does not describe an all-passing canonical corpus"
            )
        }
    }

    private func compare(
        _ primary: PEXExternalExtractorCorpusReport.CaseResult,
        _ oracle: PEXExternalExtractorCorpusReport.CaseResult,
        corpusCase: PEXExtractorCorpus.Case?,
        primaryBackendID: String,
        oracleBackendID: String
    ) throws -> PEXExtractorCorrelation.CaseComparison {
        guard let corpusCase,
              primary.coverageTags == corpusCase.coverageTags,
              oracle.coverageTags == corpusCase.coverageTags,
              primary.topCell == corpusCase.topCell,
              oracle.topCell == corpusCase.topCell,
              primary.corner == corpusCase.corner,
              oracle.corner == corpusCase.corner,
              primary.corners?.sorted() == corpusCase.corners,
              oracle.corners?.sorted() == corpusCase.corners else {
            throw PEXExtractorCorrelationBuildError.corpusCaseMismatch(caseID: primary.caseID)
        }
        guard primary.status == "passed" else {
            throw PEXExtractorCorrelationBuildError.caseNotPassed(
                caseID: primary.caseID,
                backendID: primaryBackendID
            )
        }
        guard oracle.status == "passed" else {
            throw PEXExtractorCorrelationBuildError.caseNotPassed(
                caseID: oracle.caseID,
                backendID: oracleBackendID
            )
        }
        let metricInputs = [
            MetricInput(
                id: "totalGroundCapacitanceF",
                primaryObserved: primary.totalGroundCapF,
                oracleObserved: oracle.totalGroundCapF,
                primaryExpected: primary.expectedGroundCapF,
                oracleExpected: oracle.expectedGroundCapF,
                primaryTolerance: primary.groundCapToleranceF ?? primary.toleranceF,
                oracleTolerance: oracle.groundCapToleranceF ?? oracle.toleranceF,
                corpusExpected: corpusCase.expectedGroundCapF,
                corpusTolerance: corpusCase.groundCapToleranceF
            ),
            MetricInput(
                id: "totalCouplingCapacitanceF",
                primaryObserved: primary.totalCouplingCapF,
                oracleObserved: oracle.totalCouplingCapF,
                primaryExpected: primary.expectedCouplingCapF,
                oracleExpected: oracle.expectedCouplingCapF,
                primaryTolerance: primary.couplingCapToleranceF ?? primary.toleranceF,
                oracleTolerance: oracle.couplingCapToleranceF ?? oracle.toleranceF,
                corpusExpected: corpusCase.expectedCouplingCapF,
                corpusTolerance: corpusCase.couplingCapToleranceF
            ),
            MetricInput(
                id: "totalCapacitanceF",
                primaryObserved: primary.totalCapacitanceF,
                oracleObserved: oracle.totalCapacitanceF,
                primaryExpected: primary.expectedTotalCapacitanceF,
                oracleExpected: oracle.expectedTotalCapacitanceF,
                primaryTolerance: primary.totalCapacitanceToleranceF ?? primary.toleranceF,
                oracleTolerance: oracle.totalCapacitanceToleranceF ?? oracle.toleranceF,
                corpusExpected: corpusCase.expectedTotalCapacitanceF,
                corpusTolerance: corpusCase.totalCapacitanceToleranceF
            ),
            MetricInput(
                id: "totalResistanceOhm",
                primaryObserved: primary.totalResistanceOhm,
                oracleObserved: oracle.totalResistanceOhm,
                primaryExpected: primary.expectedResistanceOhm,
                oracleExpected: oracle.expectedResistanceOhm,
                primaryTolerance: primary.resistanceToleranceOhm,
                oracleTolerance: oracle.resistanceToleranceOhm,
                corpusExpected: corpusCase.expectedResistanceOhm,
                corpusTolerance: corpusCase.resistanceToleranceOhm
            ),
        ]
        let metrics = try metricInputs.compactMap { input in
            try metricComparison(
                input,
                caseID: primary.caseID,
                primaryBackendID: primaryBackendID,
                oracleBackendID: oracleBackendID
            )
        }
        guard !metrics.isEmpty else {
            throw PEXExtractorCorrelationBuildError.noComparableMetrics(caseID: primary.caseID)
        }
        return PEXExtractorCorrelation.CaseComparison(
            caseID: primary.caseID,
            coverageTags: primary.coverageTags,
            metrics: metrics
        )
    }

    private func metricComparison(
        _ input: MetricInput,
        caseID: String,
        primaryBackendID: String,
        oracleBackendID: String
    ) throws -> PEXExtractorCorrelation.MetricComparison? {
        guard input.corpusExpected != nil || input.corpusTolerance != nil else { return nil }
        guard let expected = input.corpusExpected,
              let tolerance = input.corpusTolerance,
              let primaryExpected = input.primaryExpected,
              let oracleExpected = input.oracleExpected,
              let primaryTolerance = input.primaryTolerance,
              let oracleTolerance = input.oracleTolerance,
              primaryExpected == expected,
              oracleExpected == expected,
              primaryTolerance == tolerance,
              oracleTolerance == tolerance else {
            throw PEXExtractorCorrelationBuildError.expectedMetricMismatch(
                caseID: caseID,
                metricID: input.id
            )
        }
        guard let primaryObserved = input.primaryObserved else {
            throw PEXExtractorCorrelationBuildError.missingMetric(
                caseID: caseID,
                metricID: input.id,
                backendID: primaryBackendID
            )
        }
        guard let oracleObserved = input.oracleObserved else {
            throw PEXExtractorCorrelationBuildError.missingMetric(
                caseID: caseID,
                metricID: input.id,
                backendID: oracleBackendID
            )
        }
        return PEXExtractorCorrelation.MetricComparison(
            metricID: input.id,
            primaryObserved: primaryObserved,
            oracleObserved: oracleObserved,
            expected: expected,
            absoluteTolerance: tolerance
        )
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func corpusSpec(_ spec: String, identifies corpusID: String) -> Bool {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let filename = URL(filePath: trimmed).deletingPathExtension().lastPathComponent
        return trimmed == corpusID || filename == corpusID
    }
}

private struct MetricInput: Sendable {
    let id: String
    let primaryObserved: Double?
    let oracleObserved: Double?
    let primaryExpected: Double?
    let oracleExpected: Double?
    let primaryTolerance: Double?
    let oracleTolerance: Double?
    let corpusExpected: Double?
    let corpusTolerance: Double?
}
