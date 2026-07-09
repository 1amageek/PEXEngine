import Foundation

public struct SPEFCorpusToolEvidenceExport: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let status: String
    public let reportPath: String
    public let reportSHA256: String?
    public let summary: SPEFCorpus.Summary
    public let toolEvidence: SPEFCorpus.ToolEvidence

    public init(
        schemaVersion: Int = 1,
        reportPath: String,
        reportSHA256: String? = nil,
        report: SPEFCorpus.Report,
        evidenceID: String? = nil,
        checkedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.status = report.qualification.qualified ? "passed" : "failed"
        self.reportPath = reportPath
        self.reportSHA256 = reportSHA256
        self.summary = report.summary
        self.toolEvidence = SPEFCorpus.ToolEvidence(
            evidenceID: evidenceID ?? Self.defaultEvidenceID(reportPath: reportPath),
            artifact: SPEFCorpus.FileReference(
                path: reportPath,
                kind: "report",
                format: "JSON",
                sha256: reportSHA256
            ),
            qualification: SPEFCorpus.QualificationSummary(
                qualified: report.qualification.qualified,
                policyID: report.qualification.policy == .strict ? "strict" : "custom",
                observedMetrics: Self.observedMetrics(report),
                observedCounts: Self.observedCounts(report),
                failureCodes: report.qualification.failures.map(\.code)
            ),
            checkedAt: Self.iso8601String(from: checkedAt)
        )
    }

    private static func defaultEvidenceID(reportPath: String) -> String {
        let filename = URL(filePath: reportPath).deletingPathExtension().lastPathComponent
        return filename.isEmpty ? "pex-spef-corpus" : "pex-spef-corpus:\(filename)"
    }

    private static func observedMetrics(_ report: SPEFCorpus.Report) -> [String: Double] {
        [
            "passRate": report.summary.passRate,
            "totalGroundCapF": report.summary.totalGroundCapF,
            "totalCouplingCapF": report.summary.totalCouplingCapF,
            "totalResistanceOhm": report.summary.totalResistanceOhm,
        ]
    }

    private static func observedCounts(_ report: SPEFCorpus.Report) -> [String: Int] {
        let failureOccurrenceCount = report.summary.failureCodeCounts.values.reduce(0, +)
        return [
            "caseCount": report.summary.caseCount,
            "passedCaseCount": report.summary.passedCaseCount,
            "failedCaseCount": report.summary.failedCaseCount,
            "coverageTagCount": report.summary.coverageTagCounts.count,
            "failureOccurrenceCount": failureOccurrenceCount,
            "failureCodeCount": report.summary.failureCodeCounts.count,
            "failureCodeKindCount": report.summary.failureCodeCounts.count,
            "failureCategoryCount": report.summary.failureCategoryCounts.count,
            "failureCategoryKindCount": report.summary.failureCategoryCounts.count,
            "requiredCoverageTagCount": report.qualification.policy.requiredCoverageTags.count,
            "coveredRequiredCoverageTagCount": report.qualification.policy.requiredCoverageTags.filter {
                report.summary.coverageTagCounts[$0] != nil
            }.count,
            "totalNetCount": report.summary.totalNetCount,
            "totalElementCount": report.summary.totalElementCount,
        ]
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }
}
