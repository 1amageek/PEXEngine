import Testing
import Foundation
@testable import PEXCore
@testable import PEXRuntime

@Suite("PEXExternalExtractorEvidencePacketBuilder")
struct PEXExternalExtractorEvidencePacketBuilderTests {
    @Test("External extractor evidence packet classifies mixed failures into decision diagnostics")
    func evidencePacketClassifiesMixedFailuresIntoDecisionDiagnostics() throws {
        let report = PEXExternalExtractorCorpusReport(
            schemaVersion: 1,
            corpusSpec: "Fixtures/ExternalExtractor/pex-magic-corpus.json",
            extractorBackendID: "magic",
            status: "failed",
            summary: PEXExternalExtractorCorpusReport.Summary(
                caseCount: 2,
                passedCaseCount: 0,
                failedCaseCount: 2,
                passRate: 0,
                coverageTagCounts: [
                    "pex.ground-cap": 1,
                    "pex.magic": 2,
                    "pex.physical-value": 1,
                ],
                totalGroundCapF: 1.4e-15,
                totalCouplingCapF: 0,
                totalCapacitanceF: 1.4e-15,
                totalResistanceOhm: 12,
                totalNetCount: 1,
                totalElementCount: 1
            ),
            evaluation: PEXExternalExtractorCorpusReport.Evaluation(
                policy: PEXExternalExtractorCorpusReport.Policy(
                    requiredCoverageTags: ["pex.magic", "pex.physical-value"],
                    minimumPassRate: 1
                ),
                failures: [
                    PEXExternalExtractorCorpusReport.EvaluationFailure(
                        code: "case_failure",
                        caseID: "plate",
                        failureCode: "ground_cap_out_of_tolerance"
                    ),
                    PEXExternalExtractorCorpusReport.EvaluationFailure(
                        code: "case_failure",
                        caseID: "broken-normalization",
                        failureCode: "ir_read_failed"
                    ),
                ]
            ),
            cases: [
                PEXExternalExtractorCorpusReport.CaseResult(
                    caseID: "plate",
                    status: "failed",
                    topCell: "pex_plate",
                    corner: "tt",
                    layoutPath: "pex_plate.gds",
                    sourceNetlistPath: "source.cir",
                    technologyPath: "technology.json",
                    outputDirectory: "runs/plate",
                    manifestPath: "runs/plate/manifest.json",
                    irPath: "runs/plate/ir/tt.json",
                    coverageTags: ["pex.ground-cap", "pex.magic", "pex.physical-value"],
                    totalGroundCapF: 1.4e-15,
                    totalCouplingCapF: 0,
                    totalCapacitanceF: 1.4e-15,
                    totalResistanceOhm: 12,
                    expectedGroundCapF: 4.2e-15,
                    expectedResistanceOhm: 12,
                    groundCapToleranceF: 2e-16,
                    resistanceToleranceOhm: 0.5,
                    groundCapErrorF: 2.8e-15,
                    netCount: 1,
                    elementCount: 1,
                    artifacts: [
                        try makeExternalArtifact(
                            artifactID: "plate:irPath",
                            path: "runs/plate/ir/tt.json",
                            role: "normalized",
                            kind: "parasitic-ir",
                            format: "JSON",
                            sha256: "7e0c1f61a8c7ed7f2f1a8e9f2b6631fd61a25d70564be14f6a3ac047e8feab44",
                            byteCount: 2048,
                            sourceField: "irPath"
                        ),
                        try makeExternalArtifact(
                            artifactID: "plate:layoutPath",
                            path: "pex_plate.gds",
                            role: "input",
                            kind: "layout",
                            format: "GDS",
                            sha256: "816534932c2e27e1df5a4bbfbc3bc00871df209834ca0f3f7162594b35c6ce7c",
                            byteCount: 512,
                            sourceField: "layoutPath"
                        ),
                    ],
                    failures: [
                        PEXExternalExtractorCorpusReport.CaseFailure(
                            code: "ground_cap_out_of_tolerance",
                            metric: "totalGroundCapF",
                            expected: 4.2e-15,
                            observed: 1.4e-15,
                            tolerance: 2e-16
                        ),
                    ]
                ),
                PEXExternalExtractorCorpusReport.CaseResult(
                    caseID: "broken-normalization",
                    status: "failed",
                    topCell: "pex_plate",
                    corner: "tt",
                    layoutPath: "pex_plate.gds",
                    sourceNetlistPath: "source.cir",
                    technologyPath: "technology.json",
                    outputDirectory: "runs/broken-normalization",
                    manifestPath: "runs/broken-normalization/manifest.json",
                    coverageTags: ["pex.magic"],
                    failures: [
                        PEXExternalExtractorCorpusReport.CaseFailure(
                            code: "ir_read_failed",
                            message: "The retained extractor run did not decode into ParasiticIR.",
                            status: "missing ir/tt.json"
                        ),
                    ]
                ),
            ]
        )

        let packet = PEXExternalExtractorEvidencePacketBuilder().build(
            report: report,
            packetID: "mixed-failure-packet"
        )

        #expect(packet.packetID == "mixed-failure-packet")
        #expect(packet.subject.kind == "external-extractor-corpus")
        #expect(packet.subject.backendID == "magic")
        #expect(packet.coverageTags == ["pex.ground-cap", "pex.magic", "pex.physical-value"])
        #expect(packet.intent.requestedObservations.contains("failure-diagnostics"))
        let layoutArtifact = try #require(packet.inputs.first { $0.reference.artifactID == "plate:layoutPath" })
        #expect(layoutArtifact.reference.sha256 == "816534932c2e27e1df5a4bbfbc3bc00871df209834ca0f3f7162594b35c6ce7c")
        #expect(layoutArtifact.reference.byteCount == 512)
        let irArtifact = try #require(packet.artifacts.first { $0.reference.artifactID == "plate:irPath" })
        #expect(irArtifact.reference.sha256 == "7e0c1f61a8c7ed7f2f1a8e9f2b6631fd61a25d70564be14f6a3ac047e8feab44")
        #expect(irArtifact.reference.byteCount == 2048)
        #expect(packet.readiness == [
            PEXEvidenceReadiness(
                component: "external-extractor-execution",
                status: .ready,
                reason: "At least one retained external extractor case produced normalized PEX evidence."
            ),
        ])

        let physicalMetric = try #require(packet.metrics.first {
            $0.name == "totalGroundCapF" && $0.caseID == "plate"
        })
        #expect(physicalMetric.value == 1.4e-15)
        #expect(physicalMetric.expectedValue == 4.2e-15)
        #expect(physicalMetric.tolerance == 2e-16)
        #expect(physicalMetric.sourceArtifactID == "plate:irPath")

        let normalizedView = try #require(packet.normalizedViews.first {
            $0.viewID == "external-extractor-physical-summary"
        })
        #expect(normalizedView.sourceArtifactIDs == ["plate:irPath"])
        #expect(normalizedView.summaryCounts["failedCaseCount"] == 2)
        #expect(normalizedView.summaryCounts["physicalBoundDeclaredCount"] == 2)
        #expect(normalizedView.summaryCounts["physicalBoundEvaluatedCount"] == 2)
        #expect(normalizedView.summaryCounts["physicalBoundPassedCount"] == 1)
        #expect(normalizedView.summaryCounts["physicalBoundFailedCount"] == 1)
        #expect(normalizedView.summaryCounts["physicalBoundMissingObservationCount"] == 0)
        #expect(normalizedView.summaryCounts["physicalBoundMissingExpectationCount"] == 0)
        #expect(normalizedView.summaryMetrics["totalGroundCapF"] == 1.4e-15)
        #expect(normalizedView.summaryMetrics["totalResistanceOhm"] == 12)
        #expect(normalizedView.summaryMetrics["physicalBoundPassRate"] == 0.5)
        #expect(normalizedView.summaryMetrics["physicalBoundEvaluationRate"] == 1)

        let boundPassRateMetric = packet.metrics.first { metric in
            metric.name == "physicalBoundPassRate"
                && metric.scope == "external-extractor-corpus"
        }
        #expect(boundPassRateMetric?.value == 0.5)
        let boundEvaluationRateMetric = packet.metrics.first { metric in
            metric.name == "physicalBoundEvaluationRate"
                && metric.scope == "external-extractor-corpus"
        }
        #expect(boundEvaluationRateMetric?.value == 1)
        let resistanceMetric = try #require(packet.metrics.first {
            $0.name == "totalResistanceOhm" && $0.caseID == "plate"
        })
        #expect(resistanceMetric.value == 12)
        #expect(resistanceMetric.expectedValue == 12)
        #expect(resistanceMetric.tolerance == 0.5)
        #expect(resistanceMetric.sourceArtifactID == "plate:irPath")

        let physicalDiagnostic = try #require(packet.diagnostics.first {
            $0.code == "ground_cap_out_of_tolerance" && $0.category == "physical_bound_mismatch"
        })
        #expect(physicalDiagnostic.severity == .error)
        #expect(physicalDiagnostic.observedValue == 1.4e-15)
        #expect(physicalDiagnostic.expectedValue == 4.2e-15)
        #expect(physicalDiagnostic.tolerance == 2e-16)
        #expect(physicalDiagnostic.artifactIDs.contains("plate:irPath"))
        #expect(physicalDiagnostic.suggestedActions.contains("check_extractor_units"))

        let normalizationDiagnostic = try #require(packet.diagnostics.first {
            $0.code == "ir_read_failed" && $0.category == "normalization_failure"
        })
        #expect(normalizationDiagnostic.severity == .error)
        #expect(normalizationDiagnostic.observedText == "missing ir/tt.json")
        #expect(normalizationDiagnostic.artifactIDs.isEmpty)
        #expect(normalizationDiagnostic.suggestedActions.contains("inspect_parasitic_ir_artifact"))

        #expect(packet.decisionHints.contains {
            $0.action == "check_extractor_units"
                && $0.relatedDiagnosticIDs.contains(physicalDiagnostic.diagnosticID)
                && $0.artifactIDs.contains("plate:irPath")
        })
        #expect(packet.decisionHints.contains {
            $0.action == "inspect_parasitic_ir_artifact"
                && $0.relatedDiagnosticIDs.contains(normalizationDiagnostic.diagnosticID)
                && $0.artifactIDs.isEmpty
        })
        #expect(packet.confidence.level == .medium)
        #expect(packet.confidence.uncertainties.contains("The external extractor corpus evaluation did not pass."))
    }

    @Test("External extractor evidence packet preserves multi-corner comparison basis")
    func evidencePacketPreservesMultiCornerComparisonBasis() throws {
        let corners = [
            PEXExtractorRunResult.CornerSummary(
                cornerID: "tt",
                status: .success,
                netCount: 1,
                elementCount: 1,
                rawOutputCount: 1,
                warningCount: 0,
                totalCapacitanceF: 1e-15,
                totalResistanceOhm: 1
            ),
            PEXExtractorRunResult.CornerSummary(
                cornerID: "ss",
                status: .success,
                netCount: 1,
                elementCount: 1,
                rawOutputCount: 1,
                warningCount: 0,
                totalCapacitanceF: 2e-15,
                totalResistanceOhm: 2
            ),
        ]
        let report = makeExternalExtractorReport(cases: [
            PEXExternalExtractorCorpusReport.CaseResult(
                caseID: "process-corners",
                status: "passed",
                corners: ["tt", "ss"],
                multiCorner: PEXExtractorMultiCornerSummary(
                    cornerResults: corners,
                    comparisonBasis: .perCornerTechnology
                ),
                coverageTags: ["pex.magic", "pex.multi-corner"],
                totalCapacitanceF: 3e-15,
                totalResistanceOhm: 3
            ),
        ])

        let packet = PEXExternalExtractorEvidencePacketBuilder().build(report: report)
        let normalizedView = try #require(packet.normalizedViews.first {
            $0.viewID == "external-extractor-physical-summary"
        })

        #expect(normalizedView.summaryAttributes["multiCornerComparisonBasis"] == "perCornerTechnology")
        #expect(normalizedView.summaryAttributes["multiCornerComparisonBasisValues"] == "perCornerTechnology")
    }

    @Test("External extractor evidence packet exposes failure taxonomy for Agent decisions")
    func evidencePacketExposesFailureTaxonomyForAgentDecisions() throws {
        let report = PEXExternalExtractorCorpusReport(
            schemaVersion: 1,
            corpusSpec: "Fixtures/ExternalExtractor/pex-negative-corpus.json",
            extractorBackendID: "magic",
            status: "failed",
            summary: PEXExternalExtractorCorpusReport.Summary(
                caseCount: 5,
                passedCaseCount: 0,
                failedCaseCount: 5,
                passRate: 0,
                coverageTagCounts: [
                    "pex.magic": 5,
                    "pex.physical-value": 2,
                    "pex.multi-corner": 5,
                ],
                totalGroundCapF: 1e-3,
                totalCouplingCapF: 0,
                totalCapacitanceF: 1e-3,
                totalResistanceOhm: 900,
                totalNetCount: 2,
                totalElementCount: 3
            ),
            evaluation: PEXExternalExtractorCorpusReport.Evaluation(
                policy: PEXExternalExtractorCorpusReport.Policy(
                    requiredCoverageTags: ["pex.magic", "pex.physical-value"],
                    minimumPassRate: 1
                ),
                failures: [
                    PEXExternalExtractorCorpusReport.EvaluationFailure(
                        code: "case_failure",
                        caseID: "unit-scale",
                        failureCode: "unit_mismatch"
                    ),
                ]
            ),
            cases: [
                PEXExternalExtractorCorpusReport.CaseResult(
                    caseID: "tool-missing",
                    status: "failed",
                    corner: "tt",
                    layoutPath: "missing-tool.gds",
                    manifestPath: "runs/tool-missing/manifest.json",
                    coverageTags: ["pex.magic", "pex.multi-corner"],
                    failures: [
                        PEXExternalExtractorCorpusReport.CaseFailure(
                            code: "extract_command_failed",
                            message: "Missing extractor executable in the configured toolchain.",
                            status: "magic: command not found"
                        ),
                    ]
                ),
                PEXExternalExtractorCorpusReport.CaseResult(
                    caseID: "profile-missing",
                    status: "failed",
                    corner: "tt",
                    layoutPath: "profile-missing.gds",
                    manifestPath: "runs/profile-missing/manifest.json",
                    coverageTags: ["pex.magic", "pex.multi-corner"],
                    failures: [
                        PEXExternalExtractorCorpusReport.CaseFailure(
                            code: "process_profile_resolution_failed",
                            message: "The PDK process profile could not resolve its technology file.",
                            status: "sky130 profile unresolved"
                        ),
                    ]
                ),
                PEXExternalExtractorCorpusReport.CaseResult(
                    caseID: "parse-failed",
                    status: "failed",
                    corner: "ss",
                    layoutPath: "parse-failed.gds",
                    manifestPath: "runs/parse-failed/manifest.json",
                    coverageTags: ["pex.magic", "pex.multi-corner"],
                    failures: [
                        PEXExternalExtractorCorpusReport.CaseFailure(
                            code: "spef_parse_failed",
                            message: "The retained extractor SPEF output could not be parsed.",
                            status: "bad *D_NET record"
                        ),
                    ]
                ),
                PEXExternalExtractorCorpusReport.CaseResult(
                    caseID: "unit-scale",
                    status: "failed",
                    corner: "ff",
                    layoutPath: "unit-scale.gds",
                    manifestPath: "runs/unit-scale/manifest.json",
                    irPath: "runs/unit-scale/ir/ff.json",
                    coverageTags: ["pex.magic", "pex.physical-value", "pex.multi-corner"],
                    totalGroundCapF: 1e-3,
                    expectedGroundCapF: 1e-15,
                    groundCapToleranceF: 1e-16,
                    failures: [
                        PEXExternalExtractorCorpusReport.CaseFailure(
                            code: "unit_mismatch",
                            metric: "totalGroundCapF",
                            expected: 1e-15,
                            observed: 1e-3,
                            tolerance: 1e-16,
                            message: "Unit scale mismatch between extractor output and canonical capacitance.",
                            status: "observed millifarads while expected farads"
                        ),
                    ]
                ),
                PEXExternalExtractorCorpusReport.CaseResult(
                    caseID: "physical-mismatch",
                    status: "failed",
                    corner: "ss",
                    layoutPath: "physical-mismatch.gds",
                    manifestPath: "runs/physical-mismatch/manifest.json",
                    irPath: "runs/physical-mismatch/ir/ss.json",
                    coverageTags: ["pex.magic", "pex.physical-value", "pex.multi-corner"],
                    totalResistanceOhm: 900,
                    expectedResistanceOhm: 100,
                    resistanceToleranceOhm: 10,
                    failures: [
                        PEXExternalExtractorCorpusReport.CaseFailure(
                            code: "resistance_out_of_tolerance",
                            metric: "totalResistanceOhm",
                            expected: 100,
                            observed: 900,
                            tolerance: 10
                        ),
                    ]
                ),
            ]
        )

        let packet = PEXExternalExtractorEvidencePacketBuilder().build(
            report: report,
            packetID: "negative-taxonomy-packet"
        )

        let classes = Set(packet.failureClassifications.map(\.failureClass))
        #expect(classes.isSuperset(of: [
            .missingExtractorReadiness,
            .processProfileError,
            .parseFailure,
            .unitMismatch,
            .physicalBoundMismatch,
            .perCornerFailure,
            .evaluationFailure,
        ]))

        let readiness = try classification(.missingExtractorReadiness, in: packet)
        #expect(readiness.severity == .blocked)
        #expect(readiness.caseIDs.contains("tool-missing"))
        #expect(readiness.cornerIDs.contains("tt"))
        #expect(readiness.reasonCodes.contains("extract_command_failed"))
        #expect(readiness.suggestedActions.contains("check_extractor_readiness_before_rerun"))

        let processProfile = try classification(.processProfileError, in: packet)
        #expect(processProfile.reasonCodes.contains("process_profile_resolution_failed"))
        #expect(processProfile.caseIDs.contains("profile-missing"))
        #expect(processProfile.suggestedActions.contains("inspect_process_profile_resolution"))

        let parse = try classification(.parseFailure, in: packet)
        #expect(parse.reasonCodes.contains("spef_parse_failed"))
        #expect(parse.caseIDs.contains("parse-failed"))
        #expect(parse.suggestedActions.contains("verify_output_format"))

        let unit = try classification(.unitMismatch, in: packet)
        #expect(unit.metricIDs == ["totalGroundCapF"])
        #expect(unit.caseIDs.contains("unit-scale"))
        #expect(unit.cornerIDs.contains("ff"))
        #expect(unit.artifactIDs.isEmpty)
        #expect(unit.suggestedActions.contains("check_extractor_units"))

        let physical = try classification(.physicalBoundMismatch, in: packet)
        #expect(physical.metricIDs == ["totalResistanceOhm"])
        #expect(physical.caseIDs.contains("physical-mismatch"))
        #expect(physical.cornerIDs.contains("ss"))
        #expect(physical.suggestedActions.contains("inspect_external_pex_physical_bounds"))

        let perCorner = try classification(.perCornerFailure, in: packet)
        #expect(Set(perCorner.caseIDs) == [
            "parse-failed",
            "physical-mismatch",
            "profile-missing",
            "tool-missing",
            "unit-scale",
        ])
        #expect(Set(perCorner.cornerIDs) == ["ff", "ss", "tt"])
        #expect(perCorner.suggestedActions.contains("rerun_failed_corners"))

        let evaluation = try classification(.evaluationFailure, in: packet)
        #expect(evaluation.caseIDs.contains("unit-scale"))
        #expect(evaluation.reasonCodes.contains("unit_mismatch"))
        #expect(evaluation.suggestedActions.contains("review_evaluation_policy"))

        let normalizedView = try #require(packet.normalizedViews.first {
            $0.viewID == "external-extractor-physical-summary"
        })
        #expect(normalizedView.summaryCounts["failureClass:missing_extractor_readiness"] == 1)
        #expect(normalizedView.summaryCounts["failureClass:process_profile_error"] == 1)
        #expect(normalizedView.summaryCounts["failureClass:parse_failure"] == 1)
        #expect(normalizedView.summaryCounts["failureClass:unit_mismatch"] == 1)
        #expect(normalizedView.summaryCounts["failureClass:physical_bound_mismatch"] == 1)
        #expect(normalizedView.summaryCounts["failureClass:per_corner_failure"] == 1)
        #expect(normalizedView.summaryCounts["failureClass:evaluation_failure"] == 1)

        let encoded = try JSONEncoder().encode(packet)
        let decoded = try JSONDecoder().decode(PEXEvidencePacket.self, from: encoded)
        #expect(decoded.failureClassifications == packet.failureClassifications)
    }

    @Test("Physical bounds audit classifies pass fail and missing evidence")
    func physicalBoundsAuditClassifiesPassFailAndMissingEvidence() throws {
        let report = PEXExternalExtractorCorpusReport(
            schemaVersion: 1,
            corpusSpec: "Fixtures/ExternalExtractor/pex-magic-corpus.json",
            extractorBackendID: "magic",
            status: "failed",
            summary: PEXExternalExtractorCorpusReport.Summary(
                caseCount: 3,
                passedCaseCount: 1,
                failedCaseCount: 2,
                passRate: 1.0 / 3.0,
                coverageTagCounts: [
                    "pex.magic": 3,
                    "pex.physical-value": 3,
                    "pex.ground-cap": 1,
                    "pex.coupling-cap": 1,
                    "pex.resistance": 2,
                ],
                totalGroundCapF: 1.05e-15,
                totalCouplingCapF: 5e-15,
                totalCapacitanceF: 0,
                totalResistanceOhm: 30,
                totalNetCount: 3,
                totalElementCount: 5
            ),
            evaluation: PEXExternalExtractorCorpusReport.Evaluation(
                policy: PEXExternalExtractorCorpusReport.Policy(
                    requiredCoverageTags: ["pex.magic", "pex.physical-value"],
                    minimumPassRate: 1
                ),
                failures: []
            ),
            cases: [
                PEXExternalExtractorCorpusReport.CaseResult(
                    caseID: "plate-pass",
                    status: "passed",
                    corner: "tt",
                    coverageTags: ["pex.magic", "pex.physical-value", "pex.ground-cap", "pex.resistance"],
                    totalGroundCapF: 1.05e-15,
                    totalResistanceOhm: 10,
                    expectedGroundCapF: 1e-15,
                    expectedResistanceOhm: 10,
                    groundCapToleranceF: 1e-16,
                    resistanceToleranceOhm: 0.25
                ),
                PEXExternalExtractorCorpusReport.CaseResult(
                    caseID: "inverter-mismatch",
                    status: "failed",
                    corner: "tt",
                    coverageTags: ["pex.magic", "pex.physical-value", "pex.coupling-cap"],
                    totalCouplingCapF: 5e-15,
                    expectedCouplingCapF: 2e-15,
                    expectedTotalCapacitanceF: 3e-15,
                    couplingCapToleranceF: 1e-16,
                    totalCapacitanceToleranceF: 1e-16
                ),
                PEXExternalExtractorCorpusReport.CaseResult(
                    caseID: "resistance-missing-tolerance",
                    status: "failed",
                    corner: "ss",
                    coverageTags: ["pex.magic", "pex.physical-value", "pex.resistance"],
                    totalResistanceOhm: 20,
                    expectedResistanceOhm: 20
                ),
            ]
        )

        let audit = PEXExternalExtractorPhysicalBoundsAuditor().audit(
            report: report,
            reportPath: "/tmp/pex-real-extractor-report.json",
            auditID: "physical-bounds-audit"
        )

        #expect(audit.auditID == "physical-bounds-audit")
        #expect(audit.status == .incomplete)
        #expect(audit.summary.caseCount == 3)
        #expect(audit.summary.declaredMetricCount == 5)
        #expect(audit.summary.evaluatedMetricCount == 3)
        #expect(audit.summary.passedMetricCount == 2)
        #expect(audit.summary.failedMetricCount == 1)
        #expect(audit.summary.missingObservationCount == 1)
        #expect(audit.summary.missingExpectationCount == 1)
        #expect(audit.summary.passRate == 2.0 / 3.0)
        #expect(audit.summary.evaluationRate == 3.0 / 5.0)

        let groundSummary = try #require(audit.metricSummaries.first { $0.metricID == "totalGroundCapF" })
        #expect(groundSummary.unit == "F")
        #expect(groundSummary.declaredCount == 1)
        #expect(groundSummary.passedCount == 1)
        #expect(groundSummary.passRate == 1)

        let couplingSummary = try #require(audit.metricSummaries.first { $0.metricID == "totalCouplingCapF" })
        #expect(couplingSummary.declaredCount == 1)
        #expect(couplingSummary.failedCount == 1)
        #expect(couplingSummary.passRate == 0)

        let totalCapSummary = try #require(audit.metricSummaries.first { $0.metricID == "totalCapacitanceF" })
        #expect(totalCapSummary.declaredCount == 1)
        #expect(totalCapSummary.missingObservationCount == 1)
        #expect(totalCapSummary.evaluationRate == 0)

        let resistanceSummary = try #require(audit.metricSummaries.first { $0.metricID == "totalResistanceOhm" })
        #expect(resistanceSummary.declaredCount == 2)
        #expect(resistanceSummary.evaluatedCount == 1)
        #expect(resistanceSummary.passedCount == 1)
        #expect(resistanceSummary.missingExpectationCount == 1)

        let mismatchCase = try #require(audit.caseSummaries.first { $0.caseID == "inverter-mismatch" })
        #expect(mismatchCase.failedMetrics == ["totalCapacitanceF", "totalCouplingCapF"])
        #expect(mismatchCase.failedMetricCount == 1)
        #expect(mismatchCase.missingObservationCount == 1)

        #expect(audit.diagnostics.contains {
            $0.code == "physical_bound_failed"
                && $0.caseID == "inverter-mismatch"
                && $0.metricID == "totalCouplingCapF"
                && $0.observed == 5e-15
                && $0.expected == 2e-15
                && $0.tolerance == 1e-16
        })
        #expect(audit.diagnostics.contains {
            $0.code == "physical_bound_missing_observation"
                && $0.caseID == "inverter-mismatch"
                && $0.metricID == "totalCapacitanceF"
        })
        #expect(audit.diagnostics.contains {
            $0.code == "physical_bound_missing_expectation"
                && $0.caseID == "resistance-missing-tolerance"
                && $0.metricID == "totalResistanceOhm"
        })
        #expect(audit.suggestedActions.contains("check_extractor_units"))
        #expect(audit.suggestedActions.contains("complete_external_pex_expected_bounds"))

        let packet = PEXExternalExtractorEvidencePacketBuilder().build(report: report)
        let physicalSummary = try #require(packet.normalizedViews.first {
            $0.viewID == "external-extractor-physical-summary"
        })
        #expect(physicalSummary.summaryCounts["physicalBoundDeclaredCount"] == audit.summary.declaredMetricCount)
        #expect(physicalSummary.summaryCounts["physicalBoundEvaluatedCount"] == audit.summary.evaluatedMetricCount)
        #expect(physicalSummary.summaryCounts["physicalBoundPassedCount"] == audit.summary.passedMetricCount)
        #expect(physicalSummary.summaryCounts["physicalBoundFailedCount"] == audit.summary.failedMetricCount)
        #expect(physicalSummary.summaryCounts["physicalBoundMissingObservationCount"] == audit.summary.missingObservationCount)
        #expect(physicalSummary.summaryCounts["physicalBoundMissingExpectationCount"] == audit.summary.missingExpectationCount)
        #expect(physicalSummary.summaryMetrics["physicalBoundPassRate"] == audit.summary.passRate)
        #expect(physicalSummary.summaryMetrics["physicalBoundEvaluationRate"] == audit.summary.evaluationRate)
    }

    @Test("Physical bounds audit treats exact tolerance boundary as pass")
    func physicalBoundsAuditTreatsToleranceBoundaryAsPassAndOutsideAsFailure() throws {
        let report = makeExternalExtractorReport(cases: [
            PEXExternalExtractorCorpusReport.CaseResult(
                caseID: "resistance-boundary-pass",
                status: "passed",
                corner: "tt",
                coverageTags: ["pex.magic", "pex.physical-value", "pex.resistance"],
                totalResistanceOhm: 11,
                expectedResistanceOhm: 10,
                resistanceToleranceOhm: 1
            ),
            PEXExternalExtractorCorpusReport.CaseResult(
                caseID: "resistance-outside-fail",
                status: "failed",
                corner: "tt",
                coverageTags: ["pex.magic", "pex.physical-value", "pex.resistance"],
                totalResistanceOhm: 11.01,
                expectedResistanceOhm: 10,
                resistanceToleranceOhm: 1
            ),
        ])

        let audit = PEXExternalExtractorPhysicalBoundsAuditor().audit(report: report)

        #expect(audit.status == .incomplete)
        #expect(audit.summary.declaredMetricCount == 2)
        #expect(audit.summary.evaluatedMetricCount == 2)
        #expect(audit.summary.passedMetricCount == 1)
        #expect(audit.summary.failedMetricCount == 1)
        #expect(audit.summary.passRate == 0.5)
        #expect(!audit.diagnostics.contains { $0.caseID == "resistance-boundary-pass" })
        #expect(audit.diagnostics.contains {
            $0.code == "physical_bound_failed"
                && $0.caseID == "resistance-outside-fail"
                && $0.metricID == "totalResistanceOhm"
                && $0.observed == 11.01
                && $0.expected == 10
                && $0.tolerance == 1
        })
    }

    @Test("Physical bounds audit explains a corpus with no declared expected bounds")
    func physicalBoundsAuditExplainsMissingDeclaredBounds() throws {
        let report = makeExternalExtractorReport(cases: [
            PEXExternalExtractorCorpusReport.CaseResult(
                caseID: "retained-run-without-bounds",
                status: "passed",
                corner: "tt",
                coverageTags: ["pex.magic", "pex.physical-value", "pex.ground-cap"],
                totalGroundCapF: 1.2e-15,
                totalResistanceOhm: 8
            ),
        ])

        let audit = PEXExternalExtractorPhysicalBoundsAuditor().audit(report: report)

        #expect(audit.status == .incomplete)
        #expect(audit.summary.declaredMetricCount == 0)
        #expect(audit.summary.evaluatedMetricCount == 0)
        #expect(audit.summary.passRate == 0)
        #expect(audit.summary.evaluationRate == 0)
        #expect(audit.diagnostics == [
            PEXExternalExtractorPhysicalBoundsAudit.Diagnostic(
                diagnosticID: "physical-bound:corpus:physical-bounds:physical_bound_missing_declarations",
                code: "physical_bound_missing_declarations",
                severity: "warning",
                caseID: "corpus",
                metricID: "physical-bounds",
                suggestedActions: [
                    "declare_external_pex_expected_bounds",
                    "inspect_corpus_manifest",
                ]
            ),
        ])
        #expect(audit.suggestedActions == [
            "declare_external_pex_expected_bounds",
            "inspect_corpus_manifest",
        ])
    }

    @Test("Physical bounds audit flags a partially undeclared physical value case")
    func physicalBoundsAuditFlagsPartiallyUndeclaredPhysicalValueCase() throws {
        let report = makeExternalExtractorReport(cases: [
            PEXExternalExtractorCorpusReport.CaseResult(
                caseID: "plate-pass",
                status: "passed",
                corner: "tt",
                coverageTags: ["pex.magic", "pex.physical-value", "pex.ground-cap"],
                totalGroundCapF: 1.05e-15,
                expectedGroundCapF: 1e-15,
                groundCapToleranceF: 1e-16
            ),
            PEXExternalExtractorCorpusReport.CaseResult(
                caseID: "plate-missing-bounds",
                status: "passed",
                corner: "tt",
                coverageTags: ["pex.magic", "pex.physical-value", "pex.ground-cap"],
                totalGroundCapF: 1.2e-15
            ),
        ])

        let audit = PEXExternalExtractorPhysicalBoundsAuditor().audit(report: report)

        #expect(audit.status == .incomplete)
        #expect(audit.summary.declaredMetricCount == 1)
        #expect(audit.summary.evaluatedMetricCount == 1)
        #expect(audit.summary.passedMetricCount == 1)
        #expect(audit.diagnostics.contains {
            $0.code == "physical_bound_missing_declarations"
                && $0.caseID == "plate-missing-bounds"
                && $0.metricID == "totalGroundCapF"
                && $0.suggestedActions.contains("declare_external_pex_expected_bounds")
        })

        let undeclaredCase = try #require(audit.caseSummaries.first {
            $0.caseID == "plate-missing-bounds"
        })
        #expect(undeclaredCase.failedMetrics == ["totalGroundCapF"])
    }

    @Test("Physical bounds audit flags coarse physical-value metrics without specific tags")
    func physicalBoundsAuditFlagsCoarsePhysicalValueObservedMetricsWithoutSpecificTags() throws {
        let report = makeExternalExtractorReport(cases: [
            PEXExternalExtractorCorpusReport.CaseResult(
                caseID: "mixed-physical-values",
                status: "passed",
                corner: "tt",
                coverageTags: ["pex.magic", "pex.physical-value", "pex.resistance"],
                totalGroundCapF: 1.2e-15,
                totalResistanceOhm: 10,
                expectedResistanceOhm: 10,
                resistanceToleranceOhm: 0.25
            ),
        ])

        let audit = PEXExternalExtractorPhysicalBoundsAuditor().audit(report: report)

        #expect(audit.status == .incomplete)
        #expect(audit.summary.declaredMetricCount == 1)
        #expect(audit.summary.evaluatedMetricCount == 1)
        #expect(audit.summary.passedMetricCount == 1)
        #expect(audit.diagnostics.contains {
            $0.code == "physical_bound_missing_declarations"
                && $0.caseID == "mixed-physical-values"
                && $0.metricID == "totalGroundCapF"
        })

        let caseSummary = try #require(audit.caseSummaries.first {
            $0.caseID == "mixed-physical-values"
        })
        #expect(caseSummary.failedMetrics == ["totalGroundCapF"])
    }

    @Test("Physical bounds audit JSON round trips schema fields for contract fixtures")
    func physicalBoundsAuditRoundTripsSchemaFields() throws {
        let report = makeExternalExtractorReport(cases: [
            PEXExternalExtractorCorpusReport.CaseResult(
                caseID: "plate",
                status: "passed",
                corner: "tt",
                coverageTags: ["pex.magic", "pex.physical-value", "pex.ground-cap"],
                totalGroundCapF: 4.2e-15,
                expectedGroundCapF: 4.2e-15,
                groundCapToleranceF: 2e-16
            ),
        ])
        let audit = PEXExternalExtractorPhysicalBoundsAuditor().audit(
            report: report,
            reportPath: "pex-real-extractor-report.json",
            auditID: "fixture-audit"
        )

        let data = try JSONEncoder().encode(audit)
        let decoded = try JSONDecoder().decode(PEXExternalExtractorPhysicalBoundsAudit.self, from: data)

        #expect(decoded.schemaVersion == PEXExternalExtractorPhysicalBoundsAudit.currentSchemaVersion)
        #expect(decoded.auditID == "fixture-audit")
        #expect(decoded.status == .satisfied)
        #expect(decoded.reportPath == "pex-real-extractor-report.json")
        #expect(decoded.metricSummaries.map(\.metricID) == [
            "totalCapacitanceF",
            "totalCouplingCapF",
            "totalGroundCapF",
            "totalResistanceOhm",
        ])
        #expect(decoded.caseSummaries.map(\.caseID) == ["plate"])
    }

    @Test("Physical bounds audit retained Magic corpus declares expected bounds")
    func physicalBoundsAuditCorpusSpecDeclaresRetainedMagicBounds() throws {
        let fixtureURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/ExternalExtractor/pex-magic-corpus.json")
        let spec = try JSONDecoder().decode(
            ExternalExtractorCorpusSpec.self,
            from: Data(contentsOf: fixtureURL)
        )

        #expect(Set(spec.evaluationPolicy.requiredCoverageTags).isSuperset(of: [
            "pex.magic",
            "pex.physical-value",
            "pex.ground-cap",
            "pex.coupling-cap",
            "pex.total-capacitance",
            "pex.resistance",
            "pex.rc-network",
        ]))
        #expect(spec.cases.count >= 4)
        for caseSpec in spec.cases {
            #expect(caseSpec.coverageTags.contains("pex.physical-value"))
            #expect(caseSpec.hasExpectedPhysicalBound)
            #expect(caseSpec.hasToleranceForDeclaredBounds)
        }
        #expect(spec.cases.contains { $0.expectedGroundCapF != nil })
        #expect(spec.cases.contains { $0.expectedCouplingCapF != nil })
        #expect(spec.cases.contains { $0.expectedTotalCapacitanceF != nil })
        #expect(spec.cases.contains { $0.expectedResistanceOhm != nil })
        #expect(Set(spec.cases.map(\.corner)).isSuperset(of: ["tt", "ss"]))
    }

    @Test("Physical bounds audit fixture regenerates from retained extractor report")
    func physicalBoundsAuditFixtureRegeneratesFromRetainedReport() throws {
        let testDirectory = URL(filePath: #filePath).deletingLastPathComponent()
        let pexEngineRoot = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspaceRoot = pexEngineRoot.deletingLastPathComponent()
        let reportURL = testDirectory
            .appending(path: "Fixtures/ExternalExtractor/pex-real-extractor-report.json")
        let fixtureURL = workspaceRoot
            .appending(path: "docs/contract-fixtures/pex-extractor-physical-bounds-audit-v1.json")
        let report = try JSONDecoder().decode(
            PEXExternalExtractorCorpusReport.self,
            from: Data(contentsOf: reportURL)
        )
        let expected = try JSONDecoder().decode(
            PEXExternalExtractorPhysicalBoundsAudit.self,
            from: Data(contentsOf: fixtureURL)
        )

        let regenerated = PEXExternalExtractorPhysicalBoundsAuditor().audit(
            report: report,
            reportPath: expected.reportPath,
            auditID: expected.auditID
        )

        #expect(regenerated == expected)
    }

    @Test("External extractor evidence packet preserves retained artifact hashes")
    func evidencePacketPreservesRetainedArtifactHashes() throws {
        let fixtureURL = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/ExternalExtractor/pex-real-extractor-report.json")
        let report = try JSONDecoder().decode(
            PEXExternalExtractorCorpusReport.self,
            from: Data(contentsOf: fixtureURL)
        )

        let packet = PEXExternalExtractorEvidencePacketBuilder().build(report: report)

        let input = try #require(packet.inputs.first { $0.reference.artifactID == "sky130-plate-magic-pex:layoutPath" })
        #expect(input.reference.sha256 == "84399133042383c99318f9c7c67cf34f71755dec3393b2e2da34c2982dec6062")
        #expect(input.reference.byteCount == 182)
        let ir = try #require(packet.artifacts.first { $0.reference.artifactID == "sky130-inverter-magic-pex-ss:irPath" })
        #expect(ir.reference.sha256 == "914fb43b9be8ebb108b66f231391e0ec7cd9d64618b1f0616b146552305abb3c")
        #expect(ir.reference.byteCount == 17645)
        let rcIR = try #require(packet.artifacts.first { $0.reference.artifactID == "sky130-inverter-magic-pex-ss:irPath" })
        #expect(rcIR.cornerID == "ss")
        #expect(packet.coverageTags.contains("pex.multi-corner"))
        #expect(packet.coverageTags.contains("pex.rc-network"))
        #expect(packet.coverageTags.contains("pex.total-capacitance"))
        #expect(packet.metrics.contains {
            $0.name == "totalCapacitanceF"
                && $0.caseID == "sky130-plate-magic-pex"
                && $0.expectedValue == 4.2008e-15
        })
        #expect(!packet.diagnostics.contains { $0.category == "physical_bound_mismatch" })
    }

    @Test("External extractor evidence packet quarantines unsafe retained artifact paths")
    func evidencePacketQuarantinesUnsafeRetainedArtifactPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PEXExternalExtractorEvidencePacketBuilderTests-\(UUID().uuidString)")
        let insideIR = root.appending(path: "runs/plate/ir.json")
        let outsideManifest = root.deletingLastPathComponent().appending(path: "outside-manifest.json")
        let report = makeExternalExtractorReport(cases: [
            PEXExternalExtractorCorpusReport.CaseResult(
                caseID: "plate",
                status: "passed",
                corner: "tt",
                layoutPath: insideIR.deletingLastPathComponent().appending(path: "layout.gds").path(percentEncoded: false),
                outputDirectory: root.appending(path: "runs/plate").path(percentEncoded: false),
                manifestPath: outsideManifest.path(percentEncoded: false),
                irPath: insideIR.path(percentEncoded: false),
                coverageTags: ["pex.magic", "pex.physical-value"],
                totalGroundCapF: 4.2e-15,
                totalResistanceOhm: 12,
                artifacts: [
                    try makeExternalArtifact(
                        artifactID: "plate:manifestPath",
                        path: outsideManifest.path(percentEncoded: false),
                        role: "output",
                        kind: "pex-artifact-manifest",
                        format: "JSON",
                        sha256: String(repeating: "a", count: 64),
                        byteCount: 1,
                        sourceField: "manifestPath"
                    ),
                ]
            ),
        ])

        let packet = PEXExternalExtractorEvidencePacketBuilder().build(
            report: report,
            packetID: "unsafe-artifact-packet",
            allowedArtifactRootPath: root.path(percentEncoded: false)
        )

        #expect(!packet.artifacts.contains { $0.reference.artifactID == "plate:manifestPath" })
        #expect(packet.diagnostics.contains {
            $0.diagnosticID == "external-case:plate:manifestPath-artifact-integrity"
                && $0.category == "artifact_integrity"
        })
        #expect(packet.readiness.contains {
            $0.component == "external-extractor-artifacts" && $0.status == .blocked
        })
        #expect(packet.confidence.level == .low)
        #expect(packet.decisionHints.contains {
            $0.action == "inspect_external_pex_artifact_paths"
        })
        #expect(packet.failureClassifications.allSatisfy {
            !$0.artifactIDs.contains("plate:manifestPath") && !$0.artifactIDs.contains("plate:rawSpefPath")
        })
    }

    @Test("External extractor evidence packet uses safe namespaces for unsafe and duplicate case IDs")
    func evidencePacketUsesSafeNamespacesForUnsafeAndDuplicateCaseIDs() throws {
        let report = makeExternalExtractorReport(cases: [
            PEXExternalExtractorCorpusReport.CaseResult(
                caseID: "case/one",
                status: "failed",
                corner: "tt",
                manifestPath: "runs/case-one/manifest.json",
                irPath: "runs/case-one/ir.json",
                totalGroundCapF: 1.0e-15,
                failures: [
                    PEXExternalExtractorCorpusReport.CaseFailure(
                        code: "ground_cap_out_of_tolerance",
                        metric: "totalGroundCapF"
                    ),
                ]
            ),
            PEXExternalExtractorCorpusReport.CaseResult(
                caseID: "case one",
                status: "passed",
                corner: "ff",
                irPath: "runs/case-one-2/ir.json",
                totalGroundCapF: 2.0e-15
            ),
            PEXExternalExtractorCorpusReport.CaseResult(
                caseID: "case/one",
                status: "passed",
                corner: "ss",
                irPath: "runs/case-one-3/ir.json",
                totalGroundCapF: 3.0e-15
            ),
        ])

        let packet = PEXExternalExtractorEvidencePacketBuilder().build(
            report: report,
            packetID: "unsafe-case-id-packet"
        )
        let caseMetricIDs = packet.metrics
            .filter { $0.name == "totalGroundCapF" && $0.scope == "case" }
            .map(\.caseID)
        let diagnosticIDs = packet.diagnostics.map(\.diagnosticID)

        #expect(caseMetricIDs == ["case-one", "case-one-2", "case-one-3"])
        #expect(packet.artifacts.isEmpty)
        #expect(Set(diagnosticIDs).count == diagnosticIDs.count)
        #expect(packet.diagnostics.contains {
            $0.diagnosticID == "external-case:case-one:case-id-unsafe"
                && $0.category == "artifact_integrity"
        })
        #expect(packet.diagnostics.contains {
            $0.diagnosticID == "external-case:case-one-2:case-id-namespace-collision"
                && $0.category == "artifact_integrity"
        })
        #expect(packet.diagnostics.contains {
            $0.diagnosticID == "external-case:case-one-3:case-id-duplicate"
                && $0.category == "artifact_integrity"
        })
        #expect(packet.failureClassifications.contains {
            $0.caseIDs.contains("case-one") && !$0.caseIDs.contains("case/one")
        })
        #expect(packet.failureClassifications.flatMap(\.artifactIDs).allSatisfy {
            !$0.contains("case/one")
        })
    }

    private func classification(
        _ failureClass: PEXFailureDiagnosticClass,
        in packet: PEXEvidencePacket
    ) throws -> PEXFailureDiagnosticClassification {
        try #require(packet.failureClassifications.first { $0.failureClass == failureClass })
    }

    private func makeExternalExtractorReport(
        cases: [PEXExternalExtractorCorpusReport.CaseResult]
    ) -> PEXExternalExtractorCorpusReport {
        let coverageTagCounts = cases
            .flatMap(\.coverageTags)
            .reduce(into: [String: Int]()) { counts, tag in
                counts[tag, default: 0] += 1
            }
        let passedCaseCount = cases.filter { $0.status == "passed" }.count
        let failedCaseCount = cases.count - passedCaseCount
        let passRate = cases.isEmpty ? 0 : Double(passedCaseCount) / Double(cases.count)

        return PEXExternalExtractorCorpusReport(
            schemaVersion: 1,
            corpusSpec: "Fixtures/ExternalExtractor/pex-magic-corpus.json",
            extractorBackendID: "magic",
            status: failedCaseCount == 0 ? "passed" : "failed",
            summary: PEXExternalExtractorCorpusReport.Summary(
                caseCount: cases.count,
                passedCaseCount: passedCaseCount,
                failedCaseCount: failedCaseCount,
                passRate: passRate,
                coverageTagCounts: coverageTagCounts,
                totalGroundCapF: cases.compactMap(\.totalGroundCapF).reduce(0, +),
                totalCouplingCapF: cases.compactMap(\.totalCouplingCapF).reduce(0, +),
                totalCapacitanceF: cases.compactMap(\.totalCapacitanceF).reduce(0, +),
                totalResistanceOhm: cases.compactMap(\.totalResistanceOhm).reduce(0, +),
                totalNetCount: cases.compactMap(\.netCount).reduce(0, +),
                totalElementCount: cases.compactMap(\.elementCount).reduce(0, +)
            ),
            evaluation: PEXExternalExtractorCorpusReport.Evaluation(
                policy: PEXExternalExtractorCorpusReport.Policy(
                    requiredCoverageTags: ["pex.magic", "pex.physical-value"],
                    minimumPassRate: 1
                ),
                failures: []
            ),
            cases: cases
        )
    }

    private struct ExternalExtractorCorpusSpec: Decodable {
        let evaluationPolicy: EvaluationPolicy
        let cases: [CaseSpec]
    }

    private struct EvaluationPolicy: Decodable {
        let requiredCoverageTags: [String]
    }

    private struct CaseSpec: Decodable {
        let corner: String
        let coverageTags: [String]
        let expectedGroundCapF: Double?
        let expectedCouplingCapF: Double?
        let expectedTotalCapacitanceF: Double?
        let expectedResistanceOhm: Double?
        let groundCapToleranceF: Double?
        let couplingCapToleranceF: Double?
        let totalCapacitanceToleranceF: Double?
        let resistanceToleranceOhm: Double?
        let toleranceF: Double?

        var hasExpectedPhysicalBound: Bool {
            expectedGroundCapF != nil
                || expectedCouplingCapF != nil
                || expectedTotalCapacitanceF != nil
                || expectedResistanceOhm != nil
        }

        var hasToleranceForDeclaredBounds: Bool {
            if expectedGroundCapF != nil && groundCapToleranceF == nil && toleranceF == nil {
                return false
            }
            if expectedCouplingCapF != nil && couplingCapToleranceF == nil && toleranceF == nil {
                return false
            }
            if expectedTotalCapacitanceF != nil && totalCapacitanceToleranceF == nil && toleranceF == nil {
                return false
            }
            if expectedResistanceOhm != nil && resistanceToleranceOhm == nil {
                return false
            }
            return true
        }
    }
}

private func makeExternalArtifact(
    artifactID: String,
    path: String,
    role: String,
    kind: String,
    format: String,
    sha256: String,
    byteCount: Int,
    sourceField: String? = nil
) throws -> PEXExternalExtractorCorpusReport.CaseResult.Artifact {
    let location = path.hasPrefix("/")
        ? try ArtifactLocation(fileURL: URL(filePath: path))
        : try ArtifactLocation(workspaceRelativePath: path)
    return PEXExternalExtractorCorpusReport.CaseResult.Artifact(
        reference: ArtifactReference(
            id: try ArtifactID(rawValue: artifactID),
            locator: ArtifactLocator(
                location: location,
                role: try ArtifactRole(validatingRawValue: role),
                kind: try ArtifactKind(rawValue: kind),
                format: try ArtifactFormat(rawValue: format.lowercased())
            ),
            digest: try ContentDigest(algorithm: .sha256, hexadecimalValue: sha256),
            byteCount: UInt64(byteCount)
        ),
        sourceField: sourceField
    )
}
