import Foundation
import PEXCore

public struct SPEFCorpusEvidencePacketBuilder: Sendable {
    public init() {}

    public func build(
        report: SPEFCorpus.Report,
        packetID: String? = nil,
        allowedArtifactRootPath: String? = nil
    ) -> PEXEvidencePacket {
        let contexts = caseContexts(report.caseResults)
        let inputBuild = artifactRefs(from: report.sourceArtifacts, allowedArtifactRootPath: allowedArtifactRootPath)
        let toolEvidenceBuild = artifactRef(
            from: report.toolEvidence.artifact,
            artifactID: "tool-evidence",
            role: "qualification-evidence",
            allowedArtifactRootPath: allowedArtifactRootPath
        )
        let inputRefs = inputBuild.refs
        let toolEvidenceRefs = toolEvidenceBuild.refs
        let manifestArtifactID = inputRefs.first { $0.artifactID == "corpus-manifest" }?.artifactID
        let toolEvidenceArtifactID = toolEvidenceRefs.first?.artifactID
        let diagnostics = inputBuild.diagnostics
            + toolEvidenceBuild.diagnostics
            + contexts.flatMap(\.diagnostics)
            + diagnostics(
                from: report,
                inputRefs: inputRefs,
                contexts: contexts,
                toolEvidenceArtifactID: toolEvidenceArtifactID
            )
        let decisionHints = decisionHints(from: report, diagnostics: diagnostics, manifestArtifactID: manifestArtifactID)

        return PEXEvidencePacket(
            packetID: packetID ?? defaultPacketID(report: report),
            domain: "pex.parasitic-evidence",
            subject: PEXEvidenceSubject(
                kind: "spef-corpus",
                identifier: report.manifestPath,
                sourceRepository: report.sourceRepository,
                pinnedRevision: report.pinnedCommit,
                backendID: inferredBackendID(report)
            ),
            intent: PEXEvidenceIntent(
                summary: "Expose retained SPEF corpus observations as PEX decision material.",
                designContext: "Corpus-level parser and physical-value qualification for extracted parasitic data.",
                requestedObservations: [
                    "coverage-tags",
                    "parse-structure",
                    "physical-parasitic-totals",
                    "failure-diagnostics",
                ]
            ),
            inputs: inputRefs,
            readiness: readiness(
                report: report,
                manifestArtifactID: manifestArtifactID,
                diagnostics: diagnostics
            ),
            artifacts: toolEvidenceRefs,
            normalizedViews: normalizedViews(report: report, manifestArtifactID: manifestArtifactID),
            metrics: metrics(report: report, manifestArtifactID: manifestArtifactID),
            diagnostics: diagnostics,
            confidence: confidence(report: report, diagnostics: diagnostics),
            decisionHints: decisionHints,
            coverageTags: report.summary.coverageTagCounts.keys.sorted(),
            relatedEvidenceIDs: [report.toolEvidence.evidenceID]
        )
    }

    private func defaultPacketID(report: SPEFCorpus.Report) -> String {
        "pex-evidence-packet:\(URL(filePath: report.manifestPath).deletingPathExtension().lastPathComponent)"
    }

    private struct EvidenceCaseContext: Sendable {
        let rawCaseID: String
        let caseKey: String
        let diagnostics: [PEXEvidenceDiagnostic]
    }

    private struct ArtifactRefBuildResult: Sendable {
        var refs: [PEXEvidenceArtifactRef] = []
        var diagnostics: [PEXEvidenceDiagnostic] = []
    }

    private func caseContexts(_ caseResults: [SPEFCorpus.CaseResult]) -> [EvidenceCaseContext] {
        var usedBaseCounts: [String: Int] = [:]
        var rawCounts: [String: Int] = [:]
        return caseResults.enumerated().map { index, caseResult in
            let rawCaseID = caseResult.fileName
            let base = sanitizedCaseIdentifierToken(rawCaseID).isEmpty
                ? "case-\(index + 1)"
                : sanitizedCaseIdentifierToken(rawCaseID)
            let previousBaseCount = usedBaseCounts[base, default: 0]
            let nextBaseCount = previousBaseCount + 1
            usedBaseCounts[base] = nextBaseCount
            let caseKey = nextBaseCount == 1 ? base : "\(base)-\(nextBaseCount)"

            var diagnostics: [PEXEvidenceDiagnostic] = []
            if let reason = caseIDValidationFailure(rawCaseID) {
                diagnostics.append(caseIDDiagnostic(
                    caseKey: caseKey,
                    issueID: "unsafe-case-id",
                    rawCaseID: rawCaseID,
                    reason: reason
                ))
            }
            if rawCounts[rawCaseID, default: 0] > 0 {
                diagnostics.append(caseIDDiagnostic(
                    caseKey: caseKey,
                    issueID: "duplicate-case-id",
                    rawCaseID: rawCaseID,
                    reason: "The SPEF corpus case ID duplicates an earlier retained case."
                ))
            }
            if previousBaseCount > 0 {
                diagnostics.append(caseIDDiagnostic(
                    caseKey: caseKey,
                    issueID: "case-id-namespace-collision",
                    rawCaseID: rawCaseID,
                    reason: "The SPEF corpus case ID collides with another case after safe namespace normalization."
                ))
            }
            rawCounts[rawCaseID, default: 0] += 1
            return EvidenceCaseContext(rawCaseID: rawCaseID, caseKey: caseKey, diagnostics: diagnostics)
        }
    }

    private func artifactRefs(
        from refs: [SPEFCorpus.FileReference],
        allowedArtifactRootPath: String?
    ) -> ArtifactRefBuildResult {
        var result = ArtifactRefBuildResult()
        for (index, ref) in refs.enumerated() {
            let artifactID = index == 0 ? "corpus-manifest" : "corpus-input-\(index)"
            let built = artifactRef(
                from: ref,
                artifactID: artifactID,
                role: index == 0 ? "intent" : "input",
                allowedArtifactRootPath: allowedArtifactRootPath
            )
            result.refs += built.refs
            result.diagnostics += built.diagnostics
        }
        return result
    }

    private func artifactRef(
        from ref: SPEFCorpus.FileReference,
        artifactID: String,
        role: String,
        allowedArtifactRootPath: String?
    ) -> ArtifactRefBuildResult {
        var result = ArtifactRefBuildResult()
        if let reason = artifactPathValidationFailure(ref.path, allowedArtifactRootPath: allowedArtifactRootPath) {
            result.diagnostics.append(artifactPathDiagnostic(
                artifactID: artifactID,
                rawPath: ref.path,
                reason: reason
            ))
        } else {
            result.refs.append(PEXEvidenceArtifactRef(
                artifactID: artifactID,
                path: ref.path,
                role: role,
                kind: ref.kind,
                format: ref.format,
                sha256: ref.sha256,
                byteCount: ref.byteCount
            ))
        }
        return result
    }

    private func inferredBackendID(_ report: SPEFCorpus.Report) -> String? {
        let tags = Set(report.summary.coverageTagCounts.keys)
        if tags.contains("pex.extract.openrcx") {
            return "openrcx"
        }
        if tags.contains("pex.extract.magic") || tags.contains("pex.magic") {
            return "magic"
        }
        return nil
    }

    private func readiness(
        report: SPEFCorpus.Report,
        manifestArtifactID: String?,
        diagnostics: [PEXEvidenceDiagnostic]
    ) -> [PEXEvidenceReadiness] {
        var readiness = [
            PEXEvidenceReadiness(
                component: "spef-corpus-report",
                status: manifestArtifactID == nil ? .blocked : .ready,
                reason: manifestArtifactID == nil
                    ? "The retained corpus report has no trusted manifest artifact reference."
                    : "The retained corpus report is available for analysis.",
                artifactIDs: manifestArtifactID.map { [$0] } ?? []
            ),
            PEXEvidenceReadiness(
                component: "external-extractor-execution",
                status: .unknown,
                reason: "This packet describes retained extractor output; it does not prove that the extractor can run on this machine.",
                suggestedActions: [
                    "check_extractor_readiness_before_rerun",
                    "inspect_source_artifact_provenance",
                ]
            ),
        ]
        let artifactIntegrityDiagnostics = diagnostics.filter { $0.category == "artifact_integrity" }
        if !artifactIntegrityDiagnostics.isEmpty {
            readiness.append(PEXEvidenceReadiness(
                component: "spef-corpus-artifacts",
                status: .blocked,
                reason: "One or more retained SPEF corpus artifact references or case namespaces are unsafe to trust.",
                artifactIDs: artifactIntegrityDiagnostics.flatMap(\.artifactIDs),
                suggestedActions: artifactIntegritySuggestedActions()
            ))
        }
        return readiness
    }

    private func normalizedViews(
        report: SPEFCorpus.Report,
        manifestArtifactID: String?
    ) -> [PEXEvidenceNormalizedView] {
        [
            PEXEvidenceNormalizedView(
                viewID: "spef-corpus-lowered-summary",
                kind: "parasitic-ir-summary",
                scope: "corpus",
                unitSystem: "canonical",
                summaryMetrics: [
                    "passRate": report.summary.passRate,
                    "totalGroundCapF": report.summary.totalGroundCapF,
                    "totalCouplingCapF": report.summary.totalCouplingCapF,
                    "totalResistanceOhm": report.summary.totalResistanceOhm,
                ],
                summaryCounts: [
                    "caseCount": report.summary.caseCount,
                    "passedCaseCount": report.summary.passedCaseCount,
                    "failedCaseCount": report.summary.failedCaseCount,
                    "totalNetCount": report.summary.totalNetCount,
                    "totalElementCount": report.summary.totalElementCount,
                ],
                sourceArtifactIDs: manifestArtifactID.map { [$0] } ?? []
            )
        ]
    }

    private func metrics(
        report: SPEFCorpus.Report,
        manifestArtifactID: String?
    ) -> [PEXEvidenceMetric] {
        let sourceArtifactID = manifestArtifactID
        return [
            PEXEvidenceMetric(name: "passRate", value: report.summary.passRate, scope: "corpus", sourceArtifactID: sourceArtifactID),
            PEXEvidenceMetric(name: "caseCount", value: Double(report.summary.caseCount), unit: "count", scope: "corpus", sourceArtifactID: sourceArtifactID),
            PEXEvidenceMetric(name: "failedCaseCount", value: Double(report.summary.failedCaseCount), unit: "count", scope: "corpus", sourceArtifactID: sourceArtifactID),
            PEXEvidenceMetric(name: "coverageTagCount", value: Double(report.summary.coverageTagCounts.count), unit: "count", scope: "corpus", sourceArtifactID: sourceArtifactID),
            PEXEvidenceMetric(name: "totalGroundCapF", value: report.summary.totalGroundCapF, unit: "F", scope: "corpus", sourceArtifactID: sourceArtifactID),
            PEXEvidenceMetric(name: "totalCouplingCapF", value: report.summary.totalCouplingCapF, unit: "F", scope: "corpus", sourceArtifactID: sourceArtifactID),
            PEXEvidenceMetric(name: "totalResistanceOhm", value: report.summary.totalResistanceOhm, unit: "ohm", scope: "corpus", sourceArtifactID: sourceArtifactID),
        ]
    }

    private func diagnostics(
        from report: SPEFCorpus.Report,
        inputRefs: [PEXEvidenceArtifactRef],
        contexts: [EvidenceCaseContext],
        toolEvidenceArtifactID: String?
    ) -> [PEXEvidenceDiagnostic] {
        var diagnostics: [PEXEvidenceDiagnostic] = []

        for (caseResult, context) in zip(report.caseResults, contexts) {
            let artifactIDs = inputRefs
                .filter { $0.path == caseResult.fileName || $0.path.hasSuffix("/\(caseResult.fileName)") }
                .map(\.artifactID)
            for (index, failure) in caseResult.failures.enumerated() {
                diagnostics.append(PEXEvidenceDiagnostic(
                    diagnosticID: "case:\(context.caseKey):\(sanitizedIdentifierToken(failure.code)):\(index)",
                    code: failure.code,
                    category: failure.category ?? "case_failure",
                    severity: .error,
                    message: failure.message,
                    caseID: context.caseKey,
                    observedText: failure.observedText,
                    expectedText: failure.expectedText,
                    observedValue: failure.observedDouble,
                    expectedValue: failure.expectedDouble,
                    tolerance: failure.tolerance,
                    artifactIDs: artifactIDs,
                    suggestedActions: failure.suggestedActions
                ))
            }
        }

        for (index, failure) in report.qualification.failures.enumerated() {
            diagnostics.append(PEXEvidenceDiagnostic(
                diagnosticID: "qualification:\(sanitizedIdentifierToken(failure.code)):\(index)",
                code: failure.code,
                category: "qualification",
                severity: .error,
                message: failure.message,
                observedText: failure.observedText,
                expectedText: failure.requiredText,
                observedValue: failure.observedDouble,
                expectedValue: failure.requiredDouble,
                artifactIDs: toolEvidenceArtifactID.map { [$0] } ?? []
            ))
        }

        return diagnostics
    }

    private func confidence(
        report: SPEFCorpus.Report,
        diagnostics: [PEXEvidenceDiagnostic]
    ) -> PEXEvidenceConfidence {
        var strengths: [String] = [
            "Corpus provenance records source repository and pinned revision.",
            "Lowered parasitic totals are normalized into canonical units.",
        ]
        var uncertainties: [String] = [
            "The packet is decision material; it does not select the repair action.",
            "Retained SPEF output does not prove local extractor readiness.",
        ]

        if report.qualification.qualified {
            strengths.append("Qualification policy passed for the retained corpus.")
        } else {
            uncertainties.append("Qualification policy did not pass; inspect diagnostics before using the corpus as positive evidence.")
        }

        if report.summary.coverageTagCounts["pex.physical-value"] != nil {
            strengths.append("Physical-value coverage is represented in the retained corpus.")
        } else {
            uncertainties.append("No physical-value coverage tag is present.")
        }

        let level: PEXEvidenceConfidenceLevel
        if diagnostics.contains(where: { $0.category == "artifact_integrity" }) {
            level = .low
            uncertainties.append("Artifact integrity diagnostics block direct trust in retained SPEF corpus decision material.")
        } else if diagnostics.isEmpty && report.qualification.qualified {
            level = .high
        } else if report.summary.caseCount > 0 {
            level = .medium
        } else {
            level = .low
        }

        return PEXEvidenceConfidence(
            level: level,
            rationale: "Confidence reflects corpus qualification, retained provenance, physical coverage, and unresolved diagnostics.",
            strengths: strengths,
            uncertainties: uncertainties
        )
    }

    private func decisionHints(
        from report: SPEFCorpus.Report,
        diagnostics: [PEXEvidenceDiagnostic],
        manifestArtifactID: String?
    ) -> [PEXEvidenceDecisionHint] {
        if diagnostics.isEmpty {
            return [
                PEXEvidenceDecisionHint(
                    hintID: "inspect-physical-impact",
                    priority: .normal,
                    action: "compare_physical_metrics_against_design_intent",
                    rationale: "The retained corpus passed; the next useful analysis is whether the observed parasitics matter for the design objective.",
                    artifactIDs: manifestArtifactID.map { [$0] } ?? []
                )
            ]
        }

        let actionDiagnostics = diagnostics.flatMap { diagnostic -> [(action: String, diagnostic: PEXEvidenceDiagnostic)] in
            let actions = diagnostic.suggestedActions.isEmpty
                ? ["inspect_diagnostic_context"]
                : diagnostic.suggestedActions
            return actions.map { ($0, diagnostic) }
        }
        let actionToDiagnostics = Dictionary(grouping: actionDiagnostics, by: \.action)

        return actionToDiagnostics.keys.sorted().map { action in
            let relatedDiagnostics = (actionToDiagnostics[action] ?? []).map(\.diagnostic)
            return PEXEvidenceDecisionHint(
                hintID: "diagnostic-action:\(sanitizedIdentifierToken(action))",
                priority: .high,
                action: action,
                rationale: "One or more retained PEX diagnostics point to this inspection handle.",
                relatedDiagnosticIDs: relatedDiagnostics.map(\.diagnosticID),
                artifactIDs: relatedDiagnostics.flatMap(\.artifactIDs)
            )
        }
    }

    private func caseIDValidationFailure(_ rawCaseID: String) -> String? {
        let trimmed = rawCaseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "case ID is empty"
        }
        guard trimmed == rawCaseID else {
            return "case ID contains leading or trailing whitespace"
        }
        if rawCaseID.contains("://") {
            return "case ID contains a URL scheme"
        }
        if rawCaseID.hasPrefix("~") {
            return "case ID starts with a home-directory shortcut"
        }
        if rawCaseID.contains("/") || rawCaseID.contains("\\") {
            return "case ID contains path separators"
        }
        let components = (rawCaseID as NSString).pathComponents
        if components.contains(".") || components.contains("..") {
            return "case ID contains current-directory or parent-directory components"
        }
        if sanitizedCaseIdentifierToken(rawCaseID) != rawCaseID {
            return "case ID contains characters outside the safe evidence namespace"
        }
        return nil
    }

    private func artifactPathValidationFailure(
        _ path: String,
        allowedArtifactRootPath: String?
    ) -> String? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return "path is empty"
        }
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
            return "path is outside the allowed SPEF corpus artifact root"
        }
        return nil
    }

    private func caseIDDiagnostic(
        caseKey: String,
        issueID: String,
        rawCaseID: String,
        reason: String
    ) -> PEXEvidenceDiagnostic {
        PEXEvidenceDiagnostic(
            diagnosticID: "spef-case:\(caseKey):\(issueID)",
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
        artifactID: String,
        rawPath: String,
        reason: String
    ) -> PEXEvidenceDiagnostic {
        PEXEvidenceDiagnostic(
            diagnosticID: "spef-artifact:\(artifactID):artifact-integrity",
            code: "artifact_reference_unsafe",
            category: "artifact_integrity",
            severity: .blocked,
            message: "The SPEF corpus artifact reference is not safe to trust: \(reason)",
            observedText: rawPath,
            suggestedActions: artifactIntegritySuggestedActions()
        )
    }

    private func artifactIntegritySuggestedActions() -> [String] {
        [
            "inspect_spef_corpus_artifact_paths",
            "regenerate_spef_corpus_report",
        ]
    }

    private func sanitizedCaseIdentifierToken(_ value: String) -> String {
        sanitizedIdentifierToken(value, extraAllowedCharacters: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func sanitizedIdentifierToken(
        _ value: String,
        extraAllowedCharacters: String = ""
    ) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-\(extraAllowedCharacters)"))
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
