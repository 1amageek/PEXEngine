import Foundation
import PEXCore

public struct PEXExternalExtractorEvidencePacketBuilder: Sendable {
    public init() {}

    public func build(
        report: PEXExternalExtractorCorpusReport,
        packetID: String? = nil,
        allowedArtifactRootPath: String? = nil
    ) -> PEXEvidencePacket {
        let contexts = caseContexts(report.cases)
        let inputsBuild = inputRefs(report, contexts: contexts, allowedArtifactRootPath: allowedArtifactRootPath)
        let outputsBuild = outputRefs(report, contexts: contexts, allowedArtifactRootPath: allowedArtifactRootPath)
        let inputs = inputsBuild.refs
        let artifacts = outputsBuild.refs
        let integrityDiagnostics = contexts.flatMap(\.diagnostics) + inputsBuild.diagnostics + outputsBuild.diagnostics
        let readiness = readiness(report, integrityDiagnostics: integrityDiagnostics)
        let diagnostics = diagnostics(report: report, contexts: contexts, artifactEvidence: inputs + artifacts)
            + integrityDiagnostics
        let rawFailureClassifications = PEXExternalExtractorFailureDiagnosticClassifier().classify(
            report: report,
            readiness: readiness,
            diagnostics: diagnostics
        )
        let failureClassifications = sanitizeFailureClassifications(
            rawFailureClassifications,
            contexts: contexts,
            retainedArtifactIDs: Set((inputs + artifacts).map { $0.reference.id.rawValue })
        )
        return PEXEvidencePacket(
            packetID: packetID ?? defaultPacketID(report),
            domain: "pex.parasitic-evidence",
            subject: PEXEvidenceSubject(
                kind: "external-extractor-corpus",
                identifier: report.corpusSpec,
                backendID: report.extractorBackendID
            ),
            intent: PEXEvidenceIntent(
                summary: "Expose retained real-extractor PEX observations as decision material.",
                designContext: "External extractor corpus with physical capacitance and resistance bounds.",
                cornerIDs: Array(Set(report.cases.flatMap { caseResult -> [String] in
                    if let corners = caseResult.corners {
                        return corners
                    }
                    if let corner = caseResult.corner {
                        return [corner]
                    }
                    return []
                })).sorted(),
                targetNets: [],
                requestedObservations: [
                    "extractor-readiness",
                    "raw-extractor-artifacts",
                    "normalized-parasitic-ir",
                    "physical-bound-evaluation",
                    "failure-diagnostics",
                ]
            ),
            inputs: inputs,
            readiness: readiness,
            artifacts: artifacts,
            normalizedViews: normalizedViews(
                report: report,
                artifactEvidence: artifacts,
                failureClassifications: failureClassifications
            ),
            metrics: metrics(report, contexts: contexts),
            diagnostics: diagnostics,
            failureClassifications: failureClassifications,
            confidence: confidence(report: report, diagnostics: diagnostics),
            decisionHints: decisionHints(report: report, contexts: contexts, diagnostics: diagnostics),
            coverageTags: report.summary.coverageTagCounts.keys.sorted(),
            relatedEvidenceIDs: ["pex-external-extractor:\(report.extractorBackendID)"]
        )
    }

    private func defaultPacketID(_ report: PEXExternalExtractorCorpusReport) -> String {
        "pex-evidence-packet:external:\(report.extractorBackendID):\(URL(filePath: report.corpusSpec).deletingPathExtension().lastPathComponent)"
    }

    private struct EvidenceCaseContext {
        let result: PEXExternalExtractorCorpusReport.CaseResult
        let caseKey: String
        let rawCaseID: String?
        let diagnostics: [PEXEvidenceDiagnostic]
    }

    private struct ArtifactRefBuildResult {
        var refs: [PEXEvidenceArtifact]
        var diagnostics: [PEXEvidenceDiagnostic]
    }

    private func caseContexts(
        _ cases: [PEXExternalExtractorCorpusReport.CaseResult]
    ) -> [EvidenceCaseContext] {
        var rawCaseIDCounts: [String: Int] = [:]
        for caseResult in cases {
            let trimmedCaseID = caseResult.caseID.trimmingCharacters(in: .whitespacesAndNewlines)
            rawCaseIDCounts[trimmedCaseID, default: 0] += 1
        }

        var namespaceCounts: [String: Int] = [:]
        return cases.enumerated().map { index, caseResult in
            let trimmedCaseID = caseResult.caseID.trimmingCharacters(in: .whitespacesAndNewlines)
            var baseKey = sanitizedIdentifierToken(trimmedCaseID)
            if baseKey.isEmpty {
                baseKey = "case-\(index + 1)"
            }
            let occurrence = namespaceCounts[baseKey, default: 0] + 1
            namespaceCounts[baseKey] = occurrence
            let caseKey = occurrence == 1 ? baseKey : "\(baseKey)-\(occurrence)"
            var diagnostics: [PEXEvidenceDiagnostic] = []

            if trimmedCaseID.isEmpty {
                diagnostics.append(caseIDDiagnostic(
                    caseKey: caseKey,
                    issueID: "case-id-empty",
                    rawCaseID: nil,
                    reason: "The external PEX corpus case ID is empty and cannot be used as a stable evidence namespace."
                ))
            } else if trimmedCaseID != caseResult.caseID || trimmedCaseID != baseKey {
                diagnostics.append(caseIDDiagnostic(
                    caseKey: caseKey,
                    issueID: "case-id-unsafe",
                    rawCaseID: trimmedCaseID,
                    reason: "The external PEX corpus case ID contains characters that are not valid in evidence artifact IDs."
                ))
            }

            if rawCaseIDCounts[trimmedCaseID, default: 0] > 1 {
                diagnostics.append(caseIDDiagnostic(
                    caseKey: caseKey,
                    issueID: "case-id-duplicate",
                    rawCaseID: trimmedCaseID.isEmpty ? nil : trimmedCaseID,
                    reason: "The external PEX corpus case ID is duplicated and would otherwise collide in evidence IDs."
                ))
            } else if occurrence > 1 {
                diagnostics.append(caseIDDiagnostic(
                    caseKey: caseKey,
                    issueID: "case-id-namespace-collision",
                    rawCaseID: trimmedCaseID.isEmpty ? nil : trimmedCaseID,
                    reason: "The external PEX corpus case ID normalizes to an evidence namespace already used by another case."
                ))
            }

            return EvidenceCaseContext(
                result: caseResult,
                caseKey: caseKey,
                rawCaseID: trimmedCaseID.isEmpty ? nil : trimmedCaseID,
                diagnostics: diagnostics
            )
        }
    }

    private func inputRefs(
        _ report: PEXExternalExtractorCorpusReport,
        contexts: [EvidenceCaseContext],
        allowedArtifactRootPath: String?
    ) -> ArtifactRefBuildResult {
        var result = ArtifactRefBuildResult(refs: [], diagnostics: [])
        for context in contexts {
            appendDeclaredCaseRefs(
                &result,
                context: context,
                roles: ["input"],
                allowedArtifactRootPath: allowedArtifactRootPath
            )
        }
        result.refs = deduplicated(result.refs)
        return result
    }

    private func outputRefs(
        _ report: PEXExternalExtractorCorpusReport,
        contexts: [EvidenceCaseContext],
        allowedArtifactRootPath: String?
    ) -> ArtifactRefBuildResult {
        var result = ArtifactRefBuildResult(refs: [], diagnostics: [])
        for context in contexts {
            appendDeclaredCaseRefs(
                &result,
                context: context,
                roles: ["run-artifact", "normalized", "output"],
                allowedArtifactRootPath: allowedArtifactRootPath
            )
        }
        result.refs = deduplicated(result.refs)
        return result
    }

    private func appendDeclaredCaseRefs(
        _ result: inout ArtifactRefBuildResult,
        context: EvidenceCaseContext,
        roles: Set<String>,
        allowedArtifactRootPath: String?
    ) {
        for artifact in context.result.artifacts ?? []
        where roles.contains(artifact.reference.locator.role.rawValue) {
            let sourceField = sanitizedSourceField(artifact)
            guard !sourceField.isEmpty else {
                result.diagnostics.append(artifactPathDiagnostic(
                    caseKey: context.caseKey,
                    sourceField: "declaredArtifact",
                    rawPath: artifact.reference.path,
                    reason: "declared artifact has no stable source field or artifact ID"
                ))
                continue
            }
            if let reason = artifactPathValidationFailure(
                artifact.reference.path,
                allowedArtifactRootPath: allowedArtifactRootPath
            ) {
                result.diagnostics.append(artifactPathDiagnostic(
                    caseKey: context.caseKey,
                    sourceField: sourceField,
                    rawPath: artifact.reference.path,
                    reason: reason
                ))
                continue
            }
            result.refs.append(PEXEvidenceArtifact(
                reference: artifact.reference,
                cornerID: context.result.corner
            ))
        }
    }

    private func deduplicated(_ refs: [PEXEvidenceArtifact]) -> [PEXEvidenceArtifact] {
        var byID: [ArtifactID: PEXEvidenceArtifact] = [:]
        for ref in refs {
            byID[ref.reference.id] = ref
        }
        return byID.values.sorted {
            $0.reference.id.rawValue < $1.reference.id.rawValue
        }
    }

    private func readiness(
        _ report: PEXExternalExtractorCorpusReport,
        integrityDiagnostics: [PEXEvidenceDiagnostic]
    ) -> [PEXEvidenceReadiness] {
        let failedExecutionCount = report.cases.filter { caseResult in
            caseResult.failures.contains { $0.code == "extract_command_failed" || $0.code == "extract_status_not_success" }
        }.count
        let integrityReadiness = integrityDiagnostics.isEmpty
            ? []
            : [
                PEXEvidenceReadiness(
                    component: "external-extractor-artifacts",
                    status: .blocked,
                    reason: "One or more external PEX evidence identifiers or artifact references are not safe to trust.",
                    suggestedActions: [
                        "inspect_external_pex_artifact_paths",
                        "regenerate_external_pex_corpus_report",
                    ]
                ),
            ]
        if failedExecutionCount == report.cases.count && report.cases.count > 0 {
            return integrityReadiness + [
                PEXEvidenceReadiness(
                    component: "external-extractor-execution",
                    status: .blocked,
                    reason: "Every external extractor case failed before usable normalized PEX evidence was produced.",
                    suggestedActions: [
                        "check_extractor_readiness_before_rerun",
                        "inspect_extractor_command_output",
                    ]
                )
            ]
        }
        let producedEvidenceCount = report.cases.filter { caseResult in
            caseResult.irPath != nil
                || caseResult.totalGroundCapF != nil
                || caseResult.totalCouplingCapF != nil
                || caseResult.totalResistanceOhm != nil
        }.count
        return integrityReadiness + [
            PEXEvidenceReadiness(
                component: "external-extractor-execution",
                status: producedEvidenceCount > 0 ? .ready : .unknown,
                reason: producedEvidenceCount > 0
                    ? "At least one retained external extractor case produced normalized PEX evidence."
                    : "No retained external extractor case produced normalized PEX evidence.",
                suggestedActions: producedEvidenceCount > 0 ? [] : ["inspect_external_extractor_failures"]
            )
        ]
    }

    private func normalizedViews(
        report: PEXExternalExtractorCorpusReport,
        artifactEvidence: [PEXEvidenceArtifact],
        failureClassifications: [PEXFailureDiagnosticClassification]
    ) -> [PEXEvidenceNormalizedView] {
        let physicalBounds = physicalBoundSummary(report)
        let classificationCounts = failureClassifications.reduce(into: [String: Int]()) { counts, classification in
            counts["failureClass:\(classification.failureClass.rawValue)", default: 0] += 1
        }
        var summaryCounts = [
            "caseCount": report.summary.caseCount,
            "passedCaseCount": report.summary.passedCaseCount,
            "failedCaseCount": report.summary.failedCaseCount,
            "totalNetCount": report.summary.totalNetCount,
            "totalElementCount": report.summary.totalElementCount,
            "physicalBoundDeclaredCount": physicalBounds.declaredCount,
            "physicalBoundEvaluatedCount": physicalBounds.evaluatedCount,
            "physicalBoundPassedCount": physicalBounds.passedCount,
            "physicalBoundFailedCount": physicalBounds.failedCount,
                    "physicalBoundMissingObservationCount": physicalBounds.missingObservationCount,
                    "physicalBoundMissingExpectationCount": physicalBounds.missingExpectationCount,
        ]
        summaryCounts.merge(classificationCounts) { current, _ in current }
        let comparisonBases = Set(
            report.cases.compactMap { $0.multiCorner?.comparisonBasis.rawValue }
        ).sorted()
        let summaryAttributes: [String: String]
        if comparisonBases.isEmpty {
            summaryAttributes = [:]
        } else {
            summaryAttributes = [
                "multiCornerComparisonBasis": comparisonBases.count == 1
                    ? comparisonBases[0]
                    : "mixed",
                "multiCornerComparisonBasisValues": comparisonBases.joined(separator: ","),
            ]
        }
        return [
            PEXEvidenceNormalizedView(
                viewID: "external-extractor-physical-summary",
                kind: "parasitic-ir-summary",
                scope: "external-extractor-corpus",
                unitSystem: "canonical",
                summaryMetrics: [
                    "passRate": report.summary.passRate,
                    "totalGroundCapF": report.summary.totalGroundCapF,
                    "totalCouplingCapF": report.summary.totalCouplingCapF,
                    "totalCapacitanceF": report.summary.totalCapacitanceF,
                    "totalResistanceOhm": report.summary.totalResistanceOhm,
                    "physicalBoundPassRate": physicalBounds.passRate,
                    "physicalBoundEvaluationRate": physicalBounds.evaluationRate,
                ],
                summaryCounts: summaryCounts,
                summaryAttributes: summaryAttributes,
                sourceArtifactIDs: artifactEvidence
                    .filter { $0.reference.kind.rawValue == "parasitic-ir" }
                    .map { $0.reference.id.rawValue }
            )
        ]
    }

    private func metrics(
        _ report: PEXExternalExtractorCorpusReport,
        contexts: [EvidenceCaseContext]
    ) -> [PEXEvidenceMetric] {
        var values: [PEXEvidenceMetric] = [
            PEXEvidenceMetric(name: "passRate", value: report.summary.passRate, scope: "external-extractor-corpus"),
            PEXEvidenceMetric(name: "totalGroundCapF", value: report.summary.totalGroundCapF, unit: "F", scope: "external-extractor-corpus"),
            PEXEvidenceMetric(name: "totalCouplingCapF", value: report.summary.totalCouplingCapF, unit: "F", scope: "external-extractor-corpus"),
            PEXEvidenceMetric(name: "totalCapacitanceF", value: report.summary.totalCapacitanceF, unit: "F", scope: "external-extractor-corpus"),
            PEXEvidenceMetric(name: "totalResistanceOhm", value: report.summary.totalResistanceOhm, unit: "ohm", scope: "external-extractor-corpus"),
        ]
        let physicalBounds = physicalBoundSummary(report)
        values.append(PEXEvidenceMetric(
            name: "physicalBoundPassRate",
            value: physicalBounds.passRate,
            scope: "external-extractor-corpus"
        ))
        values.append(PEXEvidenceMetric(
            name: "physicalBoundEvaluationRate",
            value: physicalBounds.evaluationRate,
            scope: "external-extractor-corpus"
        ))
        for context in contexts {
            let caseResult = context.result
            appendMetric(&values, context: context, name: "totalGroundCapF", value: caseResult.totalGroundCapF, unit: "F", expected: caseResult.expectedGroundCapF, tolerance: caseResult.groundCapToleranceF ?? caseResult.toleranceF)
            appendMetric(&values, context: context, name: "totalCouplingCapF", value: caseResult.totalCouplingCapF, unit: "F", expected: caseResult.expectedCouplingCapF, tolerance: caseResult.couplingCapToleranceF ?? caseResult.toleranceF)
            appendMetric(&values, context: context, name: "totalCapacitanceF", value: caseResult.totalCapacitanceF, unit: "F", expected: caseResult.expectedTotalCapacitanceF, tolerance: caseResult.totalCapacitanceToleranceF ?? caseResult.toleranceF)
            appendMetric(&values, context: context, name: "totalResistanceOhm", value: caseResult.totalResistanceOhm, unit: "ohm", expected: caseResult.expectedResistanceOhm, tolerance: caseResult.resistanceToleranceOhm)
        }
        return values
    }

    private func appendMetric(
        _ values: inout [PEXEvidenceMetric],
        context: EvidenceCaseContext,
        name: String,
        value: Double?,
        unit: String,
        expected: Double?,
        tolerance: Double?
    ) {
        guard let value else { return }
        values.append(PEXEvidenceMetric(
            name: name,
            value: value,
            unit: unit,
            scope: "case",
            caseID: context.caseKey,
            cornerID: context.result.corner,
            expectedValue: expected,
            tolerance: tolerance,
            sourceArtifactID: context.result.irPath.map { _ in "\(context.caseKey):irPath" }
        ))
    }

    private func physicalBoundSummary(_ report: PEXExternalExtractorCorpusReport) -> PhysicalBoundSummary {
        var summary = PhysicalBoundSummary()
        for caseResult in report.cases {
            summary.accumulate(
                observed: caseResult.totalGroundCapF,
                expected: caseResult.expectedGroundCapF,
                tolerance: caseResult.groundCapToleranceF ?? caseResult.toleranceF
            )
            summary.accumulate(
                observed: caseResult.totalCouplingCapF,
                expected: caseResult.expectedCouplingCapF,
                tolerance: caseResult.couplingCapToleranceF ?? caseResult.toleranceF
            )
            summary.accumulate(
                observed: caseResult.totalCapacitanceF,
                expected: caseResult.expectedTotalCapacitanceF,
                tolerance: caseResult.totalCapacitanceToleranceF ?? caseResult.toleranceF
            )
            summary.accumulate(
                observed: caseResult.totalResistanceOhm,
                expected: caseResult.expectedResistanceOhm,
                tolerance: caseResult.resistanceToleranceOhm
            )
        }
        return summary
    }

    private struct PhysicalBoundSummary {
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

        mutating func accumulate(observed: Double?, expected: Double?, tolerance: Double?) {
            guard expected != nil || tolerance != nil else {
                return
            }
            declaredCount += 1
            guard let expected, let tolerance else {
                missingExpectationCount += 1
                return
            }
            guard let observed else {
                missingObservationCount += 1
                return
            }
            evaluatedCount += 1
            if abs(observed - expected) <= tolerance {
                passedCount += 1
            } else {
                failedCount += 1
            }
        }
    }

    private func diagnostics(
        report: PEXExternalExtractorCorpusReport,
        contexts: [EvidenceCaseContext],
        artifactEvidence: [PEXEvidenceArtifact]
    ) -> [PEXEvidenceDiagnostic] {
        var diagnostics: [PEXEvidenceDiagnostic] = []
        let contextsByRawCaseID = Dictionary(contexts.map { ($0.rawCaseID, $0) }, uniquingKeysWith: { first, _ in first })
        for context in contexts {
            let caseResult = context.result
            let caseArtifactIDs = Set(
                (context.result.artifacts ?? []).map { $0.reference.id.rawValue }
            )
            let artifactIDs = artifactEvidence
                .map { $0.reference.id.rawValue }
                .filter(caseArtifactIDs.contains)
            for (index, failure) in caseResult.failures.enumerated() {
                diagnostics.append(PEXEvidenceDiagnostic(
                    diagnosticID: "external-case:\(context.caseKey):\(failure.code):\(index)",
                    code: failure.code,
                    category: diagnosticCategory(failure.code),
                    severity: diagnosticSeverity(failure.code),
                    message: failure.message ?? diagnosticMessage(failure.code),
                    caseID: context.caseKey,
                    observedText: failure.status,
                    expectedText: failure.expectedKey,
                    observedValue: failure.observed,
                    expectedValue: failure.expected,
                    tolerance: failure.tolerance,
                    artifactIDs: artifactIDs,
                    suggestedActions: suggestedActions(failure.code)
                ))
            }
        }
        for (index, failure) in report.evaluation.failures.enumerated() {
            let context = contextsByRawCaseID[failure.caseID]
            let diagnosticCaseID = context?.caseKey ?? failure.caseID
            diagnostics.append(PEXEvidenceDiagnostic(
                diagnosticID: context.map { "external-evaluation:\($0.caseKey):\(failure.code):\(index)" }
                    ?? "external-evaluation:\(failure.code):\(index)",
                code: failure.failureCode ?? failure.code,
                category: "evaluation",
                severity: .error,
                message: "External PEX corpus evaluation did not pass.",
                caseID: diagnosticCaseID,
                observedText: failure.missingTags?.joined(separator: ","),
                suggestedActions: ["inspect_external_pex_case_failures"]
            ))
        }
        return diagnostics
    }

    private func diagnosticCategory(_ code: String) -> String {
        switch code {
        case "extract_command_failed", "extract_status_not_success":
            return "extractor_execution"
        case "ir_read_failed":
            return "normalization_failure"
        case "ground_cap_out_of_tolerance",
             "coupling_cap_out_of_tolerance",
             "total_capacitance_out_of_tolerance",
             "resistance_out_of_tolerance":
            return "physical_bound_mismatch"
        case "missing_metric_tolerance", "missing_physical_value_expectation":
            return "expectation_missing"
        default:
            return "external_extractor_failure"
        }
    }

    private func diagnosticSeverity(_ code: String) -> PEXEvidenceSeverity {
        switch code {
        case "extract_command_failed":
            return .blocked
        default:
            return .error
        }
    }

    private func diagnosticMessage(_ code: String) -> String {
        switch diagnosticCategory(code) {
        case "physical_bound_mismatch":
            return "A retained external PEX physical metric is outside its expected bound."
        case "normalization_failure":
            return "The external extractor output could not be normalized into retained PEX IR."
        case "expectation_missing":
            return "The external PEX corpus case is missing a required physical expectation or tolerance."
        case "extractor_execution":
            return "The external PEX extractor command did not produce a usable run."
        default:
            return "The external PEX corpus case failed."
        }
    }

    private func suggestedActions(_ code: String) -> [String] {
        switch diagnosticCategory(code) {
        case "physical_bound_mismatch":
            return [
                "inspect_external_pex_physical_bounds",
                "inspect_top_parasitic_nets",
                "check_extractor_units",
            ]
        case "normalization_failure":
            return [
                "inspect_parasitic_ir_artifact",
                "inspect_extractor_raw_output",
            ]
        case "expectation_missing":
            return [
                "complete_external_pex_expected_bounds",
                "inspect_corpus_manifest",
            ]
        case "extractor_execution":
            return [
                "check_extractor_readiness_before_rerun",
                "inspect_extractor_command_output",
            ]
        default:
            return ["inspect_external_pex_case_failures"]
        }
    }

    private func confidence(
        report: PEXExternalExtractorCorpusReport,
        diagnostics: [PEXEvidenceDiagnostic]
    ) -> PEXEvidenceConfidence {
        var strengths = [
            "The packet is based on retained external extractor execution results.",
            "Physical capacitance and resistance metrics are normalized into canonical PEX units.",
        ]
        var uncertainties = [
            "The packet exposes decision material and does not choose a repair action.",
        ]
        if report.evaluation.passed {
            strengths.append("The external extractor corpus evaluation passed.")
        } else {
            uncertainties.append("The external extractor corpus evaluation did not pass.")
        }
        if report.summary.coverageTagCounts["pex.physical-value"] != nil {
            strengths.append("Physical-value coverage is represented in the retained external extractor corpus.")
        } else {
            uncertainties.append("No retained physical-value coverage tag is present.")
        }
        if diagnostics.contains(where: { $0.category == "artifact_integrity" }) {
            uncertainties.append("One or more retained external extractor artifact references were not safe to trust.")
        }
        let producedEvidenceCount = report.cases.filter { caseResult in
            caseResult.irPath != nil
                || caseResult.totalGroundCapF != nil
                || caseResult.totalCouplingCapF != nil
                || caseResult.totalResistanceOhm != nil
        }.count
        let level: PEXEvidenceConfidenceLevel
        if diagnostics.contains(where: { $0.category == "artifact_integrity" }) {
            level = .low
        } else if report.evaluation.passed && diagnostics.isEmpty {
            level = .high
        } else if producedEvidenceCount > 0 {
            level = .medium
        } else {
            level = .low
        }
        return PEXEvidenceConfidence(
            level: level,
            rationale: "Confidence reflects retained external execution, physical coverage, evaluation result, and unresolved diagnostics.",
            strengths: strengths,
            uncertainties: uncertainties
        )
    }

    private func decisionHints(
        report: PEXExternalExtractorCorpusReport,
        contexts: [EvidenceCaseContext],
        diagnostics: [PEXEvidenceDiagnostic]
    ) -> [PEXEvidenceDecisionHint] {
        if diagnostics.isEmpty {
            return [
                PEXEvidenceDecisionHint(
                    hintID: "inspect-external-pex-physical-impact",
                    priority: .normal,
                    action: "compare_external_pex_metrics_against_design_intent",
                    rationale: "The external extractor corpus passed; inspect whether the retained parasitics matter for the design objective.",
                    artifactIDs: contexts.compactMap { context in
                        context.result.irPath.map { _ in "\(context.caseKey):irPath" }
                    }
                )
            ]
        }
        let actionDiagnostics = diagnostics.flatMap { diagnostic -> [(action: String, diagnostic: PEXEvidenceDiagnostic)] in
            let actions = diagnostic.suggestedActions.isEmpty
                ? ["inspect_external_pex_case_failures"]
                : diagnostic.suggestedActions
            return actions.map { ($0, diagnostic) }
        }
        let actionToDiagnostics = Dictionary(grouping: actionDiagnostics, by: \.action)
        return actionToDiagnostics.keys.sorted().map { action in
            let relatedDiagnostics = (actionToDiagnostics[action] ?? []).map(\.diagnostic)
            return PEXEvidenceDecisionHint(
                hintID: "external-diagnostic-action:\(action)",
                priority: .high,
                action: action,
                rationale: "One or more retained external PEX diagnostics point to this inspection handle.",
                relatedDiagnosticIDs: relatedDiagnostics.map(\.diagnosticID),
                artifactIDs: relatedDiagnostics.flatMap(\.artifactIDs)
            )
        }
    }

    private func sanitizeFailureClassifications(
        _ classifications: [PEXFailureDiagnosticClassification],
        contexts: [EvidenceCaseContext],
        retainedArtifactIDs: Set<String>
    ) -> [PEXFailureDiagnosticClassification] {
        let rawToCaseKey = Dictionary(
            contexts.compactMap { context -> (String, String)? in
                guard let rawCaseID = context.rawCaseID else { return nil }
                return (rawCaseID, context.caseKey)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return classifications.map { classification in
            PEXFailureDiagnosticClassification(
                classificationID: classification.classificationID,
                failureClass: classification.failureClass,
                severity: classification.severity,
                reasonCodes: classification.reasonCodes,
                backendID: classification.backendID,
                processProfileID: classification.processProfileID,
                caseIDs: classification.caseIDs.map { rawToCaseKey[$0] ?? sanitizedIdentifierToken($0) },
                cornerIDs: classification.cornerIDs,
                metricIDs: classification.metricIDs,
                diagnosticIDs: classification.diagnosticIDs,
                artifactIDs: classification.artifactIDs
                    .map { sanitizeArtifactID($0, rawToCaseKey: rawToCaseKey) }
                    .filter { retainedArtifactIDs.contains($0) },
                suggestedActions: classification.suggestedActions
            )
        }
    }

    private func sanitizeArtifactID(
        _ artifactID: String,
        rawToCaseKey: [String: String]
    ) -> String {
        guard let separator = artifactID.firstIndex(of: ":") else {
            return sanitizedIdentifierToken(artifactID)
        }
        let rawPrefix = String(artifactID[..<separator])
        let suffix = String(artifactID[artifactID.index(after: separator)...])
        let prefix = rawToCaseKey[rawPrefix] ?? sanitizedIdentifierToken(rawPrefix)
        let sanitizedSuffix = sanitizedIdentifierToken(suffix)
        return sanitizedSuffix.isEmpty ? prefix : "\(prefix):\(sanitizedSuffix)"
    }

    private func caseIDDiagnostic(
        caseKey: String,
        issueID: String,
        rawCaseID: String?,
        reason: String
    ) -> PEXEvidenceDiagnostic {
        PEXEvidenceDiagnostic(
            diagnosticID: "external-case:\(caseKey):\(issueID)",
            code: issueID.replacingOccurrences(of: "-", with: "_"),
            category: "artifact_integrity",
            severity: .blocked,
            message: reason,
            caseID: caseKey,
            observedText: rawCaseID,
            suggestedActions: artifactIntegritySuggestedActions()
        )
    }

    private func artifactPathDiagnostic(
        caseKey: String,
        sourceField: String,
        rawPath: String,
        reason: String
    ) -> PEXEvidenceDiagnostic {
        PEXEvidenceDiagnostic(
            diagnosticID: "external-case:\(caseKey):\(sourceField)-artifact-integrity",
            code: "artifact_reference_unsafe",
            category: "artifact_integrity",
            severity: .blocked,
            message: "The external PEX \(sourceField) artifact reference is not safe to trust: \(reason)",
            caseID: caseKey,
            observedText: rawPath,
            suggestedActions: artifactIntegritySuggestedActions()
        )
    }

    private func artifactPathValidationFailure(
        _ path: String,
        allowedArtifactRootPath: String?
    ) -> String? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath == path else {
            return "path contains leading or trailing whitespace"
        }
        if path.contains("://") {
            return "path contains a URL scheme"
        }
        if path.hasPrefix("~") {
            return "path starts with a home-directory shortcut"
        }
        let components = (path as NSString).pathComponents
        if components.contains(".") || components.contains("..") {
            return "path contains current-directory or parent-directory components"
        }
        guard let allowedArtifactRootPath else {
            return nil
        }
        let rootURL = URL(filePath: allowedArtifactRootPath).standardizedFileURL
        let artifactURL = path.hasPrefix("/")
            ? URL(filePath: path).standardizedFileURL
            : rootURL.appendingPathComponent(path).standardizedFileURL
        let rootPath = rootURL.path(percentEncoded: false)
        let artifactPath = artifactURL.path(percentEncoded: false)
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        guard artifactPath == rootPath || artifactPath.hasPrefix(rootPrefix) else {
            return "path is outside the allowed external PEX artifact root"
        }
        return nil
    }

    private func sanitizedSourceField(
        _ artifact: PEXExternalExtractorCorpusReport.CaseResult.Artifact
    ) -> String {
        let sourceField = artifact.sourceField?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sourceField, !sourceField.isEmpty {
            return sanitizedIdentifierToken(sourceField)
        }
        return sanitizedIdentifierToken(artifact.reference.id.rawValue)
    }

    private func artifactIntegritySuggestedActions() -> [String] {
        [
            "inspect_external_pex_artifact_paths",
            "regenerate_external_pex_corpus_report",
        ]
    }

    private func sanitizedIdentifierToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        var result = ""
        var previousWasSeparator = false
        for scalar in value.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }
}
