public struct PEXActionDomainExporter: Sendable {
    public init() {}

    public func snapshot() -> PEXActionDomainSnapshot {
        PEXActionDomainSnapshot(
            domainID: "pex-extraction",
            ownerPackages: ["PEXEngine"],
            operations: [
                extractOperation(),
                parseSPEFOperation(),
                writeSPEFOperation(),
                compareIROperation(),
                evaluateCorpusOperation(),
                exportEvidenceOperation(),
                exportEvidencePacketOperation(),
                exportExtractorEvidencePacketOperation(),
                auditExtractorPhysicalBoundsOperation(),
                summarizeRunOperation(),
                metricRecoveryObjectiveOperation(),
            ]
        )
    }

    private func extractOperation() -> PEXActionDomainOperation {
        PEXActionDomainOperation(
            operationID: "pex.extract",
            maturity: "implemented",
            inputRefs: ["layout-ref", "source-netlist-ref", "technology-ref", "corner-set"],
            preconditions: ["top-cell-known", "backend-available", "technology-resolved"],
            effects: ["pex-run-produced", "parasitic-ir-produced", "spef-or-native-output-produced"],
            producedArtifacts: ["pex-artifact-manifest", "parasitic-ir", "spef", "pex-summary"],
            verificationGates: ["tool-trust", "pex-artifacts", "pex-flow-artifacts", "artifact-integrity"],
            reversible: true
        )
    }

    private func parseSPEFOperation() -> PEXActionDomainOperation {
        PEXActionDomainOperation(
            operationID: "pex.parse-spef",
            maturity: "implemented",
            inputRefs: ["spef-ref", "corner-ref", "optional-technology-ref"],
            preconditions: ["spef-readable", "corner-id-known"],
            effects: ["parasitic-ir-produced", "parse-summary-produced"],
            producedArtifacts: ["parasitic-ir", "parse-summary"],
            verificationGates: ["schema-validation", "parasitic-ir-validation"],
            reversible: true
        )
    }

    private func writeSPEFOperation() -> PEXActionDomainOperation {
        PEXActionDomainOperation(
            operationID: "pex.write-spef",
            maturity: "implemented",
            inputRefs: ["parasitic-ir-ref", "spef-output-ref", "optional-spef-write-report-ref"],
            preconditions: ["parasitic-ir-readable", "parasitic-ir-validation-passed"],
            effects: ["spef-produced", "spef-write-report-produced", "optional-round-trip-validation-produced"],
            producedArtifacts: ["spef", "spef-write-report"],
            verificationGates: ["parasitic-ir-validation", "artifact-integrity", "optional-spef-round-trip"],
            reversible: true
        )
    }

    private func compareIROperation() -> PEXActionDomainOperation {
        PEXActionDomainOperation(
            operationID: "pex.compare-ir",
            maturity: "implemented",
            inputRefs: [
                "baseline-parasitic-ir-ref",
                "candidate-parasitic-ir-ref",
                "optional-comparison-mode",
                "optional-regression-thresholds",
                "optional-equivalence-tolerance",
                "optional-comparison-report-ref",
            ],
            preconditions: ["baseline-ir-readable", "candidate-ir-readable", "parasitic-ir-validation-passed"],
            effects: [
                "ir-comparison-report-produced",
                "parasitic-regression-diagnostics-produced",
                "optional-semantic-equivalence-diagnostics-produced",
            ],
            producedArtifacts: ["pex-ir-comparison-report"],
            verificationGates: [
                "parasitic-ir-validation",
                "schema-validation",
                "threshold-evaluation",
                "optional-semantic-equivalence",
                "artifact-integrity",
            ],
            reversible: true
        )
    }

    private func evaluateCorpusOperation() -> PEXActionDomainOperation {
        PEXActionDomainOperation(
            operationID: "pex.evaluate-spef-corpus",
            maturity: "implemented",
            inputRefs: ["spef-corpus-manifest"],
            preconditions: ["corpus-manifest-valid", "coverage-tags-declared"],
            effects: ["spef-corpus-report-written", "evaluation-result-produced"],
            producedArtifacts: ["pex-spef-corpus-report"],
            verificationGates: ["coverage-taxonomy", "duration-budget", "parasitic-ir-validation"],
            reversible: true
        )
    }

    private func exportEvidenceOperation() -> PEXActionDomainOperation {
        PEXActionDomainOperation(
            operationID: "pex.export-corpus-observations",
            maturity: "implemented",
            inputRefs: ["pex-spef-corpus-report"],
            preconditions: ["evaluated-corpus-report-readable"],
            effects: ["corpus-observations-produced"],
            producedArtifacts: ["pex-corpus-observation-export"],
            verificationGates: ["corpus-observation-validation"],
            reversible: true
        )
    }

    private func exportEvidencePacketOperation() -> PEXActionDomainOperation {
        PEXActionDomainOperation(
            operationID: "pex.export-evidence-packet",
            maturity: "implemented",
            inputRefs: ["pex-spef-corpus-report"],
            preconditions: ["corpus-report-readable"],
            effects: ["agent-readable-evidence-packet-produced"],
            producedArtifacts: ["pex-evidence-packet"],
            verificationGates: ["schema-validation", "diagnostic-material-completeness"],
            reversible: true
        )
    }

    private func exportExtractorEvidencePacketOperation() -> PEXActionDomainOperation {
        PEXActionDomainOperation(
            operationID: "pex.export-extractor-evidence-packet",
            maturity: "implemented",
            inputRefs: ["pex-real-extractor-report"],
            preconditions: ["extractor-report-readable"],
            effects: ["agent-readable-extractor-evidence-packet-produced"],
            producedArtifacts: ["pex-evidence-packet"],
            verificationGates: ["schema-validation", "physical-metric-diagnostics", "readiness-material-completeness"],
            reversible: true
        )
    }

    private func auditExtractorPhysicalBoundsOperation() -> PEXActionDomainOperation {
        PEXActionDomainOperation(
            operationID: "pex.audit-extractor-physical-bounds",
            maturity: "implemented",
            inputRefs: ["pex-real-extractor-report"],
            preconditions: ["extractor-report-readable", "expected-physical-bounds-declared"],
            effects: ["physical-bound-audit-produced", "metric-bound-diagnostics-produced"],
            producedArtifacts: ["pex-extractor-physical-bounds-audit"],
            verificationGates: ["schema-validation", "physical-bound-evaluation", "diagnostic-material-completeness"],
            reversible: true
        )
    }

    private func summarizeRunOperation() -> PEXActionDomainOperation {
        PEXActionDomainOperation(
            operationID: "pex.summarize-run",
            maturity: "implemented",
            inputRefs: ["pex-run-directory"],
            preconditions: ["pex-artifact-manifest-readable", "parasitic-ir-artifacts-readable"],
            effects: ["top-net-summary-produced", "multi-corner-spread-produced", "worst-corner-identified"],
            producedArtifacts: ["pex-summary"],
            verificationGates: ["artifact-integrity"],
            reversible: true
        )
    }

    private func metricRecoveryObjectiveOperation() -> PEXActionDomainOperation {
        PEXActionDomainOperation(
            operationID: "pex.metric-recovery-objective",
            maturity: "implemented",
            inputRefs: ["pex-summary", "pex-ir-comparison-report", "post-layout-metric-report", "source-netlist-ref", "layout-ref"],
            preconditions: ["metric-regression-detected", "parasitic-hotspot-identifiable"],
            effects: ["planning-objective-created", "candidate-layout-or-sizing-actions-bounded", "hotspot-evidence-linked"],
            producedArtifacts: ["planning-problem", "pex-metric-recovery-planning-problem"],
            verificationGates: ["schema-validation", "simulation-metric-gate", "pex-summary-gate", "artifact-integrity"],
            reversible: true
        )
    }
}
