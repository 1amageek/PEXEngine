import Foundation

public enum PEXExternalExtractorPhysicalBoundsAuditStatus: String, Sendable, Hashable, Codable {
    case satisfied
    case incomplete
}

public struct PEXExternalExtractorPhysicalBoundsAudit: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let auditID: String
    public let status: PEXExternalExtractorPhysicalBoundsAuditStatus
    public let reportPath: String?
    public let corpusSpec: String
    public let extractorBackendID: String
    public let summary: Summary
    public let metricSummaries: [MetricSummary]
    public let caseSummaries: [CaseSummary]
    public let diagnostics: [Diagnostic]
    public let suggestedActions: [String]

    public init(
        schemaVersion: Int = PEXExternalExtractorPhysicalBoundsAudit.currentSchemaVersion,
        auditID: String,
        status: PEXExternalExtractorPhysicalBoundsAuditStatus,
        reportPath: String? = nil,
        corpusSpec: String,
        extractorBackendID: String,
        summary: Summary,
        metricSummaries: [MetricSummary],
        caseSummaries: [CaseSummary],
        diagnostics: [Diagnostic],
        suggestedActions: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.auditID = auditID
        self.status = status
        self.reportPath = reportPath
        self.corpusSpec = corpusSpec
        self.extractorBackendID = extractorBackendID
        self.summary = summary
        self.metricSummaries = metricSummaries.sorted { $0.metricID < $1.metricID }
        self.caseSummaries = caseSummaries.sorted { $0.caseID < $1.caseID }
        self.diagnostics = diagnostics.sorted { $0.diagnosticID < $1.diagnosticID }
        self.suggestedActions = Array(Set(suggestedActions.filter { !$0.isEmpty })).sorted()
    }

    public struct Summary: Sendable, Hashable, Codable {
        public let caseCount: Int
        public let declaredMetricCount: Int
        public let evaluatedMetricCount: Int
        public let passedMetricCount: Int
        public let failedMetricCount: Int
        public let missingObservationCount: Int
        public let missingExpectationCount: Int
        public let passRate: Double
        public let evaluationRate: Double

        public init(
            caseCount: Int,
            declaredMetricCount: Int,
            evaluatedMetricCount: Int,
            passedMetricCount: Int,
            failedMetricCount: Int,
            missingObservationCount: Int,
            missingExpectationCount: Int,
            passRate: Double,
            evaluationRate: Double
        ) {
            self.caseCount = caseCount
            self.declaredMetricCount = declaredMetricCount
            self.evaluatedMetricCount = evaluatedMetricCount
            self.passedMetricCount = passedMetricCount
            self.failedMetricCount = failedMetricCount
            self.missingObservationCount = missingObservationCount
            self.missingExpectationCount = missingExpectationCount
            self.passRate = passRate
            self.evaluationRate = evaluationRate
        }
    }

    public struct MetricSummary: Sendable, Hashable, Codable {
        public let metricID: String
        public let unit: String
        public let declaredCount: Int
        public let evaluatedCount: Int
        public let passedCount: Int
        public let failedCount: Int
        public let missingObservationCount: Int
        public let missingExpectationCount: Int
        public let passRate: Double
        public let evaluationRate: Double

        public init(
            metricID: String,
            unit: String,
            declaredCount: Int,
            evaluatedCount: Int,
            passedCount: Int,
            failedCount: Int,
            missingObservationCount: Int,
            missingExpectationCount: Int,
            passRate: Double,
            evaluationRate: Double
        ) {
            self.metricID = metricID
            self.unit = unit
            self.declaredCount = declaredCount
            self.evaluatedCount = evaluatedCount
            self.passedCount = passedCount
            self.failedCount = failedCount
            self.missingObservationCount = missingObservationCount
            self.missingExpectationCount = missingExpectationCount
            self.passRate = passRate
            self.evaluationRate = evaluationRate
        }
    }

    public struct CaseSummary: Sendable, Hashable, Codable {
        public let caseID: String
        public let status: String
        public let corner: String?
        public let coverageTags: [String]
        public let declaredMetricCount: Int
        public let evaluatedMetricCount: Int
        public let passedMetricCount: Int
        public let failedMetricCount: Int
        public let missingObservationCount: Int
        public let missingExpectationCount: Int
        public let failedMetrics: [String]

        public init(
            caseID: String,
            status: String,
            corner: String?,
            coverageTags: [String],
            declaredMetricCount: Int,
            evaluatedMetricCount: Int,
            passedMetricCount: Int,
            failedMetricCount: Int,
            missingObservationCount: Int,
            missingExpectationCount: Int,
            failedMetrics: [String]
        ) {
            self.caseID = caseID
            self.status = status
            self.corner = corner
            self.coverageTags = Array(Set(coverageTags.filter { !$0.isEmpty })).sorted()
            self.declaredMetricCount = declaredMetricCount
            self.evaluatedMetricCount = evaluatedMetricCount
            self.passedMetricCount = passedMetricCount
            self.failedMetricCount = failedMetricCount
            self.missingObservationCount = missingObservationCount
            self.missingExpectationCount = missingExpectationCount
            self.failedMetrics = Array(Set(failedMetrics.filter { !$0.isEmpty })).sorted()
        }
    }

    public struct Diagnostic: Sendable, Hashable, Codable {
        public let diagnosticID: String
        public let code: String
        public let severity: String
        public let caseID: String
        public let metricID: String
        public let observed: Double?
        public let expected: Double?
        public let tolerance: Double?
        public let suggestedActions: [String]

        public init(
            diagnosticID: String,
            code: String,
            severity: String,
            caseID: String,
            metricID: String,
            observed: Double? = nil,
            expected: Double? = nil,
            tolerance: Double? = nil,
            suggestedActions: [String]
        ) {
            self.diagnosticID = diagnosticID
            self.code = code
            self.severity = severity
            self.caseID = caseID
            self.metricID = metricID
            self.observed = observed
            self.expected = expected
            self.tolerance = tolerance
            self.suggestedActions = Array(Set(suggestedActions.filter { !$0.isEmpty })).sorted()
        }
    }
}

public struct PEXExternalExtractorPhysicalBoundsAuditor: Sendable {
    public init() {}

    public func audit(
        report: PEXExternalExtractorCorpusReport,
        reportPath: String? = nil,
        auditID: String? = nil
    ) -> PEXExternalExtractorPhysicalBoundsAudit {
        var overall = Counter()
        var metricCounters: [String: Counter] = [:]
        var caseSummaries: [PEXExternalExtractorPhysicalBoundsAudit.CaseSummary] = []
        var diagnostics: [PEXExternalExtractorPhysicalBoundsAudit.Diagnostic] = []
        var missingDeclarationDiagnostics: [PEXExternalExtractorPhysicalBoundsAudit.Diagnostic] = []

        for caseResult in report.cases {
            var caseCounter = Counter()
            var failedMetrics: [String] = []
            var missingDeclarationMetrics: [String] = []
            for descriptor in MetricDescriptor.all {
                let result = evaluate(descriptor: descriptor, caseResult: caseResult)
                guard result.declared else {
                    if requiresDeclaration(descriptor: descriptor, caseResult: caseResult) {
                        missingDeclarationMetrics.append(descriptor.metricID)
                    }
                    continue
                }
                overall.accumulate(result)
                metricCounters[descriptor.metricID, default: Counter()].accumulate(result)
                caseCounter.accumulate(result)
                switch result.status {
                case .passed:
                    break
                case .failed:
                    failedMetrics.append(descriptor.metricID)
                    diagnostics.append(diagnostic(
                        code: "physical_bound_failed",
                        caseResult: caseResult,
                        descriptor: descriptor,
                        result: result
                    ))
                case .missingObservation:
                    failedMetrics.append(descriptor.metricID)
                    diagnostics.append(diagnostic(
                        code: "physical_bound_missing_observation",
                        caseResult: caseResult,
                        descriptor: descriptor,
                        result: result
                    ))
                case .missingExpectation:
                    failedMetrics.append(descriptor.metricID)
                    diagnostics.append(diagnostic(
                        code: "physical_bound_missing_expectation",
                        caseResult: caseResult,
                        descriptor: descriptor,
                        result: result
                    ))
                }
            }
            if missingDeclarationMetrics.isEmpty
                && caseCounter.declaredCount == 0
                && requiresPhysicalBoundDeclaration(caseResult)
            {
                missingDeclarationMetrics.append("physical-bounds")
            }
            for metricID in missingDeclarationMetrics {
                failedMetrics.append(metricID)
                missingDeclarationDiagnostics.append(missingDeclarationDiagnostic(
                    caseResult: caseResult,
                    metricID: metricID
                ))
            }
            caseSummaries.append(PEXExternalExtractorPhysicalBoundsAudit.CaseSummary(
                caseID: caseResult.caseID,
                status: caseResult.status,
                corner: caseResult.corner,
                coverageTags: caseResult.coverageTags,
                declaredMetricCount: caseCounter.declaredCount,
                evaluatedMetricCount: caseCounter.evaluatedCount,
                passedMetricCount: caseCounter.passedCount,
                failedMetricCount: caseCounter.failedCount,
                missingObservationCount: caseCounter.missingObservationCount,
                missingExpectationCount: caseCounter.missingExpectationCount,
                failedMetrics: failedMetrics
            ))
        }

        if overall.declaredCount == 0 {
            diagnostics.append(PEXExternalExtractorPhysicalBoundsAudit.Diagnostic(
                diagnosticID: "physical-bound:corpus:physical-bounds:physical_bound_missing_declarations",
                code: "physical_bound_missing_declarations",
                severity: "warning",
                caseID: "corpus",
                metricID: "physical-bounds",
                suggestedActions: actions(for: "physical_bound_missing_declarations")
            ))
        } else {
            diagnostics.append(contentsOf: missingDeclarationDiagnostics)
        }

        let metricSummaries = MetricDescriptor.all.map { descriptor in
            let counter = metricCounters[descriptor.metricID] ?? Counter()
            return PEXExternalExtractorPhysicalBoundsAudit.MetricSummary(
                metricID: descriptor.metricID,
                unit: descriptor.unit,
                declaredCount: counter.declaredCount,
                evaluatedCount: counter.evaluatedCount,
                passedCount: counter.passedCount,
                failedCount: counter.failedCount,
                missingObservationCount: counter.missingObservationCount,
                missingExpectationCount: counter.missingExpectationCount,
                passRate: counter.passRate,
                evaluationRate: counter.evaluationRate
            )
        }
        let status: PEXExternalExtractorPhysicalBoundsAuditStatus =
            diagnostics.isEmpty && overall.declaredCount > 0 ? .satisfied : .incomplete

        return PEXExternalExtractorPhysicalBoundsAudit(
            auditID: auditID ?? defaultAuditID(report: report, reportPath: reportPath),
            status: status,
            reportPath: reportPath,
            corpusSpec: report.corpusSpec,
            extractorBackendID: report.extractorBackendID,
            summary: PEXExternalExtractorPhysicalBoundsAudit.Summary(
                caseCount: report.summary.caseCount,
                declaredMetricCount: overall.declaredCount,
                evaluatedMetricCount: overall.evaluatedCount,
                passedMetricCount: overall.passedCount,
                failedMetricCount: overall.failedCount,
                missingObservationCount: overall.missingObservationCount,
                missingExpectationCount: overall.missingExpectationCount,
                passRate: overall.passRate,
                evaluationRate: overall.evaluationRate
            ),
            metricSummaries: metricSummaries,
            caseSummaries: caseSummaries,
            diagnostics: diagnostics,
            suggestedActions: suggestedActions(diagnostics)
        )
    }

    private func defaultAuditID(report: PEXExternalExtractorCorpusReport, reportPath: String?) -> String {
        if let reportPath, !reportPath.isEmpty {
            return "pex-extractor-physical-bounds-audit:\(report.extractorBackendID):\(reportPath)"
        }
        return "pex-extractor-physical-bounds-audit:\(report.extractorBackendID):\(report.corpusSpec)"
    }

    private func diagnostic(
        code: String,
        caseResult: PEXExternalExtractorCorpusReport.CaseResult,
        descriptor: MetricDescriptor,
        result: BoundEvaluation
    ) -> PEXExternalExtractorPhysicalBoundsAudit.Diagnostic {
        PEXExternalExtractorPhysicalBoundsAudit.Diagnostic(
            diagnosticID: "physical-bound:\(caseResult.caseID):\(descriptor.metricID):\(code)",
            code: code,
            severity: code == "physical_bound_failed" ? "error" : "warning",
            caseID: caseResult.caseID,
            metricID: descriptor.metricID,
            observed: result.observed,
            expected: result.expected,
            tolerance: result.tolerance,
            suggestedActions: actions(for: code)
        )
    }

    private func missingDeclarationDiagnostic(
        caseResult: PEXExternalExtractorCorpusReport.CaseResult,
        metricID: String
    ) -> PEXExternalExtractorPhysicalBoundsAudit.Diagnostic {
        PEXExternalExtractorPhysicalBoundsAudit.Diagnostic(
            diagnosticID: "physical-bound:\(caseResult.caseID):\(metricID):physical_bound_missing_declarations",
            code: "physical_bound_missing_declarations",
            severity: "warning",
            caseID: caseResult.caseID,
            metricID: metricID,
            suggestedActions: actions(for: "physical_bound_missing_declarations")
        )
    }

    private func suggestedActions(
        _ diagnostics: [PEXExternalExtractorPhysicalBoundsAudit.Diagnostic]
    ) -> [String] {
        diagnostics.flatMap(\.suggestedActions)
    }

    private func actions(for code: String) -> [String] {
        switch code {
        case "physical_bound_failed":
            return ["inspect_external_pex_physical_bounds", "check_extractor_units", "inspect_top_parasitic_nets"]
        case "physical_bound_missing_observation":
            return ["inspect_external_extractor_output", "check_parasitic_ir_retention"]
        case "physical_bound_missing_expectation":
            return ["complete_external_pex_expected_bounds", "inspect_corpus_manifest"]
        case "physical_bound_missing_declarations":
            return ["declare_external_pex_expected_bounds", "inspect_corpus_manifest"]
        default:
            return ["inspect_external_pex_case_failures"]
        }
    }

    private func evaluate(
        descriptor: MetricDescriptor,
        caseResult: PEXExternalExtractorCorpusReport.CaseResult
    ) -> BoundEvaluation {
        let observed = descriptor.observed(caseResult)
        let expected = descriptor.expected(caseResult)
        let tolerance = descriptor.tolerance(caseResult)
        guard expected != nil || tolerance != nil else {
            return BoundEvaluation(declared: false, status: .passed)
        }
        guard let expected, let tolerance else {
            return BoundEvaluation(
                declared: true,
                status: .missingExpectation,
                observed: observed,
                expected: expected,
                tolerance: tolerance
            )
        }
        guard let observed else {
            return BoundEvaluation(
                declared: true,
                status: .missingObservation,
                expected: expected,
                tolerance: tolerance
            )
        }
        let status: BoundEvaluation.Status = abs(observed - expected) <= tolerance ? .passed : .failed
        return BoundEvaluation(
            declared: true,
            status: status,
            observed: observed,
            expected: expected,
            tolerance: tolerance
        )
    }

    private func requiresDeclaration(
        descriptor: MetricDescriptor,
        caseResult: PEXExternalExtractorCorpusReport.CaseResult
    ) -> Bool {
        guard let observed = descriptor.observed(caseResult) else { return false }
        let coverageTags = Set(caseResult.coverageTags)
        return (coverageTags.contains("pex.physical-value") && observed != 0)
            || !coverageTags.intersection(descriptor.declarationCoverageTags).isEmpty
    }

    private func requiresPhysicalBoundDeclaration(
        _ caseResult: PEXExternalExtractorCorpusReport.CaseResult
    ) -> Bool {
        caseResult.coverageTags.contains("pex.physical-value")
            && MetricDescriptor.all.contains { $0.observed(caseResult) != nil }
    }

    private struct MetricDescriptor: Sendable {
        let metricID: String
        let unit: String
        let declarationCoverageTags: [String]
        let observed: @Sendable (PEXExternalExtractorCorpusReport.CaseResult) -> Double?
        let expected: @Sendable (PEXExternalExtractorCorpusReport.CaseResult) -> Double?
        let tolerance: @Sendable (PEXExternalExtractorCorpusReport.CaseResult) -> Double?

        static let all: [MetricDescriptor] = [
            MetricDescriptor(
                metricID: "totalGroundCapF",
                unit: "F",
                declarationCoverageTags: ["pex.ground-cap"],
                observed: \.totalGroundCapF,
                expected: \.expectedGroundCapF,
                tolerance: { $0.groundCapToleranceF ?? $0.toleranceF }
            ),
            MetricDescriptor(
                metricID: "totalCouplingCapF",
                unit: "F",
                declarationCoverageTags: ["pex.coupling-cap"],
                observed: \.totalCouplingCapF,
                expected: \.expectedCouplingCapF,
                tolerance: { $0.couplingCapToleranceF ?? $0.toleranceF }
            ),
            MetricDescriptor(
                metricID: "totalCapacitanceF",
                unit: "F",
                declarationCoverageTags: ["pex.total-capacitance"],
                observed: \.totalCapacitanceF,
                expected: \.expectedTotalCapacitanceF,
                tolerance: { $0.totalCapacitanceToleranceF ?? $0.toleranceF }
            ),
            MetricDescriptor(
                metricID: "totalResistanceOhm",
                unit: "ohm",
                declarationCoverageTags: ["pex.resistance"],
                observed: \.totalResistanceOhm,
                expected: \.expectedResistanceOhm,
                tolerance: \.resistanceToleranceOhm
            ),
        ]
    }

    private struct BoundEvaluation: Sendable {
        enum Status: Sendable {
            case passed
            case failed
            case missingObservation
            case missingExpectation
        }

        let declared: Bool
        let status: Status
        var observed: Double?
        var expected: Double?
        var tolerance: Double?
    }

    private struct Counter: Sendable {
        var declaredCount = 0
        var evaluatedCount = 0
        var passedCount = 0
        var failedCount = 0
        var missingObservationCount = 0
        var missingExpectationCount = 0

        var passRate: Double {
            evaluatedCount == 0 ? 0 : Double(passedCount) / Double(evaluatedCount)
        }

        var evaluationRate: Double {
            declaredCount == 0 ? 0 : Double(evaluatedCount) / Double(declaredCount)
        }

        mutating func accumulate(_ evaluation: BoundEvaluation) {
            guard evaluation.declared else { return }
            declaredCount += 1
            switch evaluation.status {
            case .passed:
                evaluatedCount += 1
                passedCount += 1
            case .failed:
                evaluatedCount += 1
                failedCount += 1
            case .missingObservation:
                missingObservationCount += 1
            case .missingExpectation:
                missingExpectationCount += 1
            }
        }
    }
}
