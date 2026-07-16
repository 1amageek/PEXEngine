import CryptoKit
import Foundation
import PEXEngine

public struct PEXMetricRecoveryMetricReport: Codable, Sendable, Equatable {
    public let status: String?
    public let source: String?
    public let gateStatus: String?
    public let gateViolations: [String]
    public let diagnostics: [PEXMetricRecoveryMetricDiagnostic]
    public let verdicts: [PEXMetricRecoveryMetricVerdict]
    public let comparedVariables: [PEXMetricRecoveryComparedVariable]
    public let requiredPostVariables: [PEXMetricRecoveryRequiredVariable]
    public let oscillationMetrics: [PEXMetricRecoveryOscillationMetric]
    public let maxAbsoluteDelta: Double?
    public let maxRelativeDelta: Double?

    public init(
        status: String? = nil,
        source: String? = nil,
        gateStatus: String? = nil,
        gateViolations: [String] = [],
        diagnostics: [PEXMetricRecoveryMetricDiagnostic] = [],
        verdicts: [PEXMetricRecoveryMetricVerdict] = [],
        comparedVariables: [PEXMetricRecoveryComparedVariable] = [],
        requiredPostVariables: [PEXMetricRecoveryRequiredVariable] = [],
        oscillationMetrics: [PEXMetricRecoveryOscillationMetric] = [],
        maxAbsoluteDelta: Double? = nil,
        maxRelativeDelta: Double? = nil
    ) {
        self.status = status
        self.source = source
        self.gateStatus = gateStatus
        self.gateViolations = gateViolations
        self.diagnostics = diagnostics
        self.verdicts = verdicts
        self.comparedVariables = comparedVariables
        self.requiredPostVariables = requiredPostVariables
        self.oscillationMetrics = oscillationMetrics
        self.maxAbsoluteDelta = maxAbsoluteDelta
        self.maxRelativeDelta = maxRelativeDelta
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case source
        case gateStatus
        case gateViolations
        case diagnostics
        case verdicts
        case comparedVariables
        case requiredPostVariables
        case oscillationMetrics
        case maxAbsoluteDelta
        case maxRelativeDelta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        gateStatus = try container.decodeIfPresent(String.self, forKey: .gateStatus)
        gateViolations = try container.decodeIfPresent([String].self, forKey: .gateViolations) ?? []
        verdicts = try container.decodeIfPresent(
            [PEXMetricRecoveryMetricVerdict].self,
            forKey: .verdicts
        ) ?? []
        comparedVariables = try container.decodeIfPresent(
            [PEXMetricRecoveryComparedVariable].self,
            forKey: .comparedVariables
        ) ?? []
        requiredPostVariables = try container.decodeIfPresent(
            [PEXMetricRecoveryRequiredVariable].self,
            forKey: .requiredPostVariables
        ) ?? []
        oscillationMetrics = try container.decodeIfPresent(
            [PEXMetricRecoveryOscillationMetric].self,
            forKey: .oscillationMetrics
        ) ?? []
        maxAbsoluteDelta = try container.decodeIfPresent(Double.self, forKey: .maxAbsoluteDelta)
        maxRelativeDelta = try container.decodeIfPresent(Double.self, forKey: .maxRelativeDelta)

        do {
            diagnostics = try container.decodeIfPresent(
                [PEXMetricRecoveryMetricDiagnostic].self,
                forKey: .diagnostics
            ) ?? []
        } catch {
            let diagnosticMessages = try container.decodeIfPresent([String].self, forKey: .diagnostics) ?? []
            diagnostics = diagnosticMessages.map {
                PEXMetricRecoveryMetricDiagnostic(
                    severity: "warning",
                    code: "post-layout-diagnostic",
                    message: $0
                )
            }
        }
    }
}

public struct PEXMetricRecoveryMetricDiagnostic: Codable, Sendable, Equatable {
    public let severity: String
    public let code: String
    public let message: String

    public init(severity: String, code: String, message: String) {
        self.severity = severity
        self.code = code
        self.message = message
    }
}

public struct PEXMetricRecoveryMetricVerdict: Codable, Sendable, Equatable {
    public let name: String
    public let status: String
    public let value: Double?
    public let target: Double?
    public let tolerance: Double?

    public init(name: String, status: String, value: Double?, target: Double?, tolerance: Double?) {
        self.name = name
        self.status = status
        self.value = value
        self.target = target
        self.tolerance = tolerance
    }
}

public struct PEXMetricRecoveryComparedVariable: Codable, Sendable, Equatable {
    public let variableName: String
    public let pointCount: Int?
    public let maxAbsoluteDelta: Double
    public let maxRelativeDelta: Double

    public init(
        variableName: String,
        pointCount: Int? = nil,
        maxAbsoluteDelta: Double,
        maxRelativeDelta: Double
    ) {
        self.variableName = variableName
        self.pointCount = pointCount
        self.maxAbsoluteDelta = maxAbsoluteDelta
        self.maxRelativeDelta = maxRelativeDelta
    }
}

public struct PEXMetricRecoveryRequiredVariable: Codable, Sendable, Equatable {
    public let variableName: String
    public let present: Bool

    public init(variableName: String, present: Bool) {
        self.variableName = variableName
        self.present = present
    }
}

public struct PEXMetricRecoveryOscillationMetric: Codable, Sendable, Equatable {
    public let variableName: String
    public let violations: [String]
    public let frequencyRelativeDelta: Double?

    public init(variableName: String, violations: [String], frequencyRelativeDelta: Double? = nil) {
        self.variableName = variableName
        self.violations = violations
        self.frequencyRelativeDelta = frequencyRelativeDelta
    }
}

public struct PEXMetricRecoveryObjectiveBuilder: Sendable {
    public init() {}

    public func build(
        summary: PEXRunSummaryReport,
        summaryPath: String,
        comparison: PEXIRComparisonReport? = nil,
        comparisonPath: String? = nil,
        metricReport: PEXMetricRecoveryMetricReport? = nil,
        metricReportPath: String? = nil,
        layoutPath: String? = nil,
        sourceNetlistPath: String? = nil,
        technologyPath: String? = nil,
        problemID: String? = nil
    ) throws -> PEXMetricRecoveryPlanningProblem {
        let summaryRefID = "pex-summary"
        let comparisonRefID = "pex-ir-comparison-report"
        let metricRefID = "post-layout-metric-report"
        let diagnostics = inputDiagnostics(
            layoutPath: layoutPath,
            sourceNetlistPath: sourceNetlistPath,
            technologyPath: technologyPath
        )
        var objectives: [PEXMetricRecoveryObjective] = []
        var hotspots: [PEXMetricRecoveryHotspot] = []

        appendCompletenessObjectives(
            summary: summary,
            summaryRefID: summaryRefID,
            objectives: &objectives
        )
        appendPEXSummaryObjectives(
            summary: summary.summary,
            summaryRefID: summaryRefID,
            objectives: &objectives,
            hotspots: &hotspots
        )
        if let comparison {
            appendComparisonObjectives(
                comparison: comparison,
                comparisonRefID: comparisonRefID,
                objectives: &objectives,
                hotspots: &hotspots
            )
        }
        if let metricReport {
            appendMetricObjectives(
                report: metricReport,
                metricRefID: metricRefID,
                objectives: &objectives
            )
        }

        let inputArtifacts = try buildInputArtifacts(
            summaryPath: summaryPath,
            comparisonPath: comparison == nil ? nil : comparisonPath,
            metricReportPath: metricReport == nil ? nil : metricReportPath,
            layoutPath: layoutPath,
            sourceNetlistPath: sourceNetlistPath,
            technologyPath: technologyPath
        )
        let allSuggestedActions = Set(objectives.flatMap(\.suggestedActions))
        let metricFailureCount = metricFailureCount(metricReport)
        let comparisonViolationCount = comparison?.summary.violationCount ?? 0
        let status = objectives.isEmpty ? "satisfied" : "actionable"
        return PEXMetricRecoveryPlanningProblem(
            problemID: problemID ?? "\(summary.summary.runID)-pex-metric-recovery",
            status: status,
            inputArtifacts: inputArtifacts,
            summary: PEXMetricRecoverySummary(
                objectiveCount: objectives.count,
                hotspotCount: hotspots.count,
                diagnosticCount: diagnostics.count,
                pexSummaryStatus: summary.summary.status,
                pexCompletenessStatus: summary.completeness.status.rawValue,
                failedCornerCount: summary.summary.multiCorner.failedCornerCount,
                comparisonViolationCount: comparisonViolationCount,
                metricFailureCount: metricFailureCount,
                suggestedActionCount: allSuggestedActions.count
            ),
            objectives: objectives,
            hotspots: hotspots,
            candidateActions: candidateActions(hasMetricReport: metricReport != nil),
            verificationGates: verificationGates(hasMetricReport: metricReport != nil),
            diagnostics: diagnostics
        )
    }

    private func appendCompletenessObjectives(
        summary: PEXRunSummaryReport,
        summaryRefID: String,
        objectives: inout [PEXMetricRecoveryObjective]
    ) {
        for issue in summary.completeness.issues {
            objectives.append(PEXMetricRecoveryObjective(
                objectiveID: stableID("pex-completeness-\(objectives.count + 1)-\(issue.kind.rawValue)"),
                domain: "pex",
                kind: "satisfy",
                priority: issue.kind == .failedCorner ? "error" : "warning",
                target: "pex-artifact-completeness",
                currentValue: nil,
                requiredValue: nil,
                unit: nil,
                sourceRefIDs: [summaryRefID],
                description: issue.message,
                evidence: [
                    PEXMetricRecoveryEvidence(key: "issueKind", stringValue: issue.kind.rawValue),
                    PEXMetricRecoveryEvidence(key: "artifactID", stringValue: issue.artifactID),
                    PEXMetricRecoveryEvidence(key: "cornerID", stringValue: issue.cornerID?.value),
                ],
                suggestedActions: [
                    "inspect_pex_artifact_manifest",
                    "rerun_pex_extraction",
                    "repair_pex_input_references",
                ]
            ))
        }
    }

    private func appendPEXSummaryObjectives(
        summary: PEXRunSummary,
        summaryRefID: String,
        objectives: inout [PEXMetricRecoveryObjective],
        hotspots: inout [PEXMetricRecoveryHotspot]
    ) {
        for corner in summary.corners {
            if corner.status != PEXRunStatus.success.rawValue {
                objectives.append(PEXMetricRecoveryObjective(
                    objectiveID: stableID("pex-corner-\(corner.cornerID)-success"),
                    domain: "pex",
                    kind: "satisfy",
                    priority: "error",
                    target: "pex-corner-success",
                    sourceRefIDs: [summaryRefID],
                    description: "Recover failed PEX corner \(corner.cornerID).",
                    evidence: [
                        PEXMetricRecoveryEvidence(key: "cornerID", stringValue: corner.cornerID),
                        PEXMetricRecoveryEvidence(key: "status", stringValue: corner.status),
                    ],
                    suggestedActions: ["inspect_pex_corner_diagnostics", "rerun_pex_extraction"]
                ))
            }
            for diagnostic in corner.diagnostics where diagnostic.severity == "error" || diagnostic.severity == "warning" {
                objectives.append(PEXMetricRecoveryObjective(
                    objectiveID: stableID("pex-diagnostic-\(corner.cornerID)-\(diagnostic.code)-\(objectives.count + 1)"),
                    domain: "pex",
                    kind: "satisfy",
                    priority: diagnostic.severity,
                    target: "resolve-pex-diagnostic",
                    sourceRefIDs: [summaryRefID],
                    description: diagnostic.message,
                    evidence: [
                        PEXMetricRecoveryEvidence(key: "cornerID", stringValue: corner.cornerID),
                        PEXMetricRecoveryEvidence(key: "diagnosticCode", stringValue: diagnostic.code),
                    ],
                    suggestedActions: ["inspect_pex_diagnostic", "repair_pex_input_references"]
                ))
            }
            for net in corner.topNets {
                let totalCapacitance = net.groundCapF + net.couplingCapF
                hotspots.append(PEXMetricRecoveryHotspot(
                    hotspotID: stableID("pex-hotspot-\(corner.cornerID)-\(net.name)"),
                    source: "pex-summary",
                    cornerID: corner.cornerID,
                    netName: net.name,
                    totalCapacitanceF: totalCapacitance,
                    totalResistanceOhm: net.resistanceOhm,
                    sourceRefIDs: [summaryRefID]
                ))
            }
        }

        appendSpreadObjective(
            spread: summary.multiCorner.totalCapacitance,
            target: "reduce-multi-corner-capacitance-spread",
            sourceRefID: summaryRefID,
            objectives: &objectives
        )
        appendSpreadObjective(
            spread: summary.multiCorner.totalResistance,
            target: "reduce-multi-corner-resistance-spread",
            sourceRefID: summaryRefID,
            objectives: &objectives
        )
    }

    private func appendSpreadObjective(
        spread: PEXCornerMetricSpreadSummary,
        target: String,
        sourceRefID: String,
        objectives: inout [PEXMetricRecoveryObjective]
    ) {
        guard spread.spread > 0 else {
            return
        }
        objectives.append(PEXMetricRecoveryObjective(
            objectiveID: stableID("pex-spread-\(spread.metric)-\(objectives.count + 1)"),
            domain: "pex",
            kind: "minimize",
            priority: "warning",
            target: target,
            currentValue: spread.spread,
            unit: spread.unit,
            sourceRefIDs: [sourceRefID],
            description: "Reduce PEX multi-corner \(spread.metric) spread.",
            evidence: [
                PEXMetricRecoveryEvidence(key: "minCornerID", stringValue: spread.minCornerID),
                PEXMetricRecoveryEvidence(key: "maxCornerID", stringValue: spread.maxCornerID),
                PEXMetricRecoveryEvidence(key: "relativeSpread", numericValue: spread.relativeSpread),
            ],
            suggestedActions: ["inspect_worst_pex_corner", "compare_post_layout_metrics"]
        ))
    }

    private func appendComparisonObjectives(
        comparison: PEXIRComparisonReport,
        comparisonRefID: String,
        objectives: inout [PEXMetricRecoveryObjective],
        hotspots: inout [PEXMetricRecoveryHotspot]
    ) {
        for violation in comparison.violations {
            objectives.append(PEXMetricRecoveryObjective(
                objectiveID: stableID("pex-ir-\(violation.netName)-\(violation.kind)-\(objectives.count + 1)"),
                domain: "pex",
                kind: "satisfy",
                priority: "error",
                target: "resolve-parasitic-ir-regression",
                currentValue: violation.observed,
                requiredValue: violation.limit,
                sourceRefIDs: [comparisonRefID],
                description: violation.message,
                evidence: [
                    PEXMetricRecoveryEvidence(key: "netName", stringValue: violation.netName),
                    PEXMetricRecoveryEvidence(key: "violationKind", stringValue: violation.kind),
                ],
                suggestedActions: [
                    "inspect_parasitic_ir_regression",
                    "inspect_dominant_parasitic_net",
                    "adjust_layout_or_parameters",
                ]
            ))
        }
        for diff in comparison.netDiffs where diff.status == "changed" {
            hotspots.append(PEXMetricRecoveryHotspot(
                hotspotID: stableID("pex-ir-diff-\(diff.netName)"),
                source: "pex-ir-comparison-report",
                netName: diff.netName,
                totalCapacitanceF: diff.candidate?.totalCapF,
                totalResistanceOhm: diff.candidate?.totalResistanceOhm,
                relativeCapDelta: diff.relativeTotalCapDelta,
                relativeResistanceDelta: diff.relativeResistanceDelta,
                sourceRefIDs: [comparisonRefID]
            ))
        }
    }

    private func appendMetricObjectives(
        report: PEXMetricRecoveryMetricReport,
        metricRefID: String,
        objectives: inout [PEXMetricRecoveryObjective]
    ) {
        let gateStatus = report.gateStatus ?? report.status
        if let gateStatus, !isPassingStatus(gateStatus) {
            objectives.append(PEXMetricRecoveryObjective(
                objectiveID: stableID("post-layout-metric-gate-\(objectives.count + 1)"),
                domain: "simulation",
                kind: "satisfy",
                priority: "error",
                target: "post-layout-metric-gate-passed",
                sourceRefIDs: [metricRefID],
                description: "Recover post-layout simulation metrics until the metric gate passes.",
                evidence: [
                    PEXMetricRecoveryEvidence(key: "gateStatus", stringValue: gateStatus),
                    PEXMetricRecoveryEvidence(key: "gateViolations", stringValues: report.gateViolations),
                    PEXMetricRecoveryEvidence(key: "maxAbsoluteDelta", numericValue: report.maxAbsoluteDelta),
                    PEXMetricRecoveryEvidence(key: "maxRelativeDelta", numericValue: report.maxRelativeDelta),
                ],
                suggestedActions: [
                    "inspect_post_layout_metric_violations",
                    "inspect_dominant_parasitic_net",
                    "rerun_post_layout_simulation_metric_gate",
                ]
            ))
        }
        for violation in report.gateViolations {
            objectives.append(PEXMetricRecoveryObjective(
                objectiveID: stableID("post-layout-gate-violation-\(objectives.count + 1)"),
                domain: "simulation",
                kind: "satisfy",
                priority: "error",
                target: "resolve-post-layout-gate-violation",
                sourceRefIDs: [metricRefID],
                description: violation,
                suggestedActions: ["inspect_post_layout_metric_violations", "adjust_layout_or_parameters"]
            ))
        }
        for verdict in report.verdicts where !isPassingStatus(verdict.status) {
            objectives.append(PEXMetricRecoveryObjective(
                objectiveID: stableID("post-layout-verdict-\(verdict.name)-\(objectives.count + 1)"),
                domain: "simulation",
                kind: "satisfy",
                priority: "error",
                target: "simulation-metric-within-tolerance",
                currentValue: verdict.value,
                requiredValue: verdict.target,
                sourceRefIDs: [metricRefID],
                description: "Recover simulation metric \(verdict.name) to its target tolerance.",
                evidence: [
                    PEXMetricRecoveryEvidence(key: "metricName", stringValue: verdict.name),
                    PEXMetricRecoveryEvidence(key: "status", stringValue: verdict.status),
                    PEXMetricRecoveryEvidence(key: "tolerance", numericValue: verdict.tolerance),
                ],
                suggestedActions: ["inspect_simulation_metric_residual", "adjust_layout_or_parameters"]
            ))
        }
        for variable in report.comparedVariables where variable.maxAbsoluteDelta > 0 || variable.maxRelativeDelta > 0 {
            objectives.append(PEXMetricRecoveryObjective(
                objectiveID: stableID("post-layout-variable-\(variable.variableName)-\(objectives.count + 1)"),
                domain: "simulation",
                kind: "minimize",
                priority: "warning",
                target: "reduce-post-layout-waveform-delta",
                currentValue: variable.maxRelativeDelta,
                unit: "ratio",
                sourceRefIDs: [metricRefID],
                description: "Reduce post-layout waveform delta for variable \(variable.variableName).",
                evidence: [
                    PEXMetricRecoveryEvidence(key: "variableName", stringValue: variable.variableName),
                    PEXMetricRecoveryEvidence(key: "pointCount", numericValue: variable.pointCount.map(Double.init)),
                    PEXMetricRecoveryEvidence(key: "maxAbsoluteDelta", numericValue: variable.maxAbsoluteDelta),
                    PEXMetricRecoveryEvidence(key: "maxRelativeDelta", numericValue: variable.maxRelativeDelta),
                ],
                suggestedActions: ["identify_post_layout_waveform_delta_source", "rerun_post_layout_comparison"]
            ))
        }
        for variable in report.requiredPostVariables where !variable.present {
            objectives.append(PEXMetricRecoveryObjective(
                objectiveID: stableID("post-layout-required-\(variable.variableName)-\(objectives.count + 1)"),
                domain: "simulation",
                kind: "satisfy",
                priority: "error",
                target: "restore-required-post-layout-variable",
                sourceRefIDs: [metricRefID],
                description: "Restore required post-layout variable \(variable.variableName).",
                evidence: [
                    PEXMetricRecoveryEvidence(key: "variableName", stringValue: variable.variableName),
                    PEXMetricRecoveryEvidence(key: "present", boolValue: variable.present),
                ],
                suggestedActions: ["inspect_post_layout_output_variables", "repair_post_layout_simulation_setup"]
            ))
        }
        for metric in report.oscillationMetrics where !metric.violations.isEmpty {
            objectives.append(PEXMetricRecoveryObjective(
                objectiveID: stableID("post-layout-oscillation-\(metric.variableName)-\(objectives.count + 1)"),
                domain: "simulation",
                kind: "satisfy",
                priority: "error",
                target: "recover-post-layout-oscillation-metric",
                sourceRefIDs: [metricRefID],
                description: "Recover post-layout oscillation metric for variable \(metric.variableName).",
                evidence: [
                    PEXMetricRecoveryEvidence(key: "variableName", stringValue: metric.variableName),
                    PEXMetricRecoveryEvidence(key: "violations", stringValues: metric.violations),
                    PEXMetricRecoveryEvidence(key: "frequencyRelativeDelta", numericValue: metric.frequencyRelativeDelta),
                ],
                suggestedActions: ["inspect_post_layout_oscillation_metric", "adjust_layout_or_parameters"]
            ))
        }
    }

    private func metricFailureCount(_ report: PEXMetricRecoveryMetricReport?) -> Int {
        guard let report else {
            return 0
        }
        var count = 0
        if let status = report.gateStatus ?? report.status, !isPassingStatus(status) {
            count += 1
        }
        count += report.gateViolations.count
        count += report.verdicts.filter { !isPassingStatus($0.status) }.count
        count += report.requiredPostVariables.filter { !$0.present }.count
        count += report.oscillationMetrics.reduce(0) { $0 + $1.violations.count }
        count += report.diagnostics.filter { $0.severity == "error" }.count
        return count
    }

    private func inputDiagnostics(
        layoutPath: String?,
        sourceNetlistPath: String?,
        technologyPath: String?
    ) -> [PEXMetricRecoveryDiagnostic] {
        [
            missingReferenceDiagnostic(path: layoutPath, refID: "layout-ref"),
            missingReferenceDiagnostic(path: sourceNetlistPath, refID: "source-netlist-ref"),
            missingReferenceDiagnostic(path: technologyPath, refID: "technology-ref"),
        ].compactMap { $0 }
    }

    private func missingReferenceDiagnostic(path: String?, refID: String) -> PEXMetricRecoveryDiagnostic? {
        guard let path, !FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return PEXMetricRecoveryDiagnostic(
            severity: "warning",
            code: "input-reference-not-readable",
            message: "Optional planning reference \(refID) is not readable at \(path).",
            sourceRefID: refID
        )
    }

    private func buildInputArtifacts(
        summaryPath: String,
        comparisonPath: String?,
        metricReportPath: String?,
        layoutPath: String?,
        sourceNetlistPath: String?,
        technologyPath: String?
    ) throws -> [ArtifactReference] {
        var references: [ArtifactReference] = []
        if let reference = try inputArtifact(id: "pex-summary", kind: "pex-summary", path: summaryPath, required: true) {
            references.append(reference)
        }
        if let comparisonPath {
            if let reference = try inputArtifact(
                id: "pex-ir-comparison-report",
                kind: "pex-ir-comparison-report",
                path: comparisonPath,
                required: true
            ) { references.append(reference) }
        }
        if let metricReportPath {
            if let reference = try inputArtifact(
                id: "post-layout-metric-report",
                kind: "post-layout-metric-report",
                path: metricReportPath,
                required: true
            ) { references.append(reference) }
        }
        if let layoutPath {
            if let reference = try inputArtifact(id: "layout-ref", kind: "layout", path: layoutPath, required: false) {
                references.append(reference)
            }
        }
        if let sourceNetlistPath {
            if let reference = try inputArtifact(
                id: "source-netlist-ref",
                kind: "source-netlist",
                path: sourceNetlistPath,
                required: false
            ) { references.append(reference) }
        }
        if let technologyPath {
            if let reference = try inputArtifact(id: "technology-ref", kind: "technology", path: technologyPath, required: false) {
                references.append(reference)
            }
        }
        return references
    }

    private func inputArtifact(
        id: String,
        kind: String,
        path: String,
        required: Bool
    ) throws -> ArtifactReference? {
        let url = URL(filePath: path)
        do {
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return ArtifactReference(
                id: try ArtifactID(rawValue: id),
                locator: ArtifactLocator(
                    location: try ArtifactLocation(fileURL: url),
                    role: .input,
                    kind: try ArtifactKind(rawValue: kind),
                    format: try ArtifactFormat(rawValue: inputArtifactFormat(path: path))
                ),
                digest: try ContentDigest(algorithm: .sha256, hexadecimalValue: hash),
                byteCount: UInt64(data.count)
            )
        } catch {
            if required {
                throw PEXError.persistenceFailed("Failed to read required input \(path)", underlying: error)
            }
            return nil
        }
    }

    private func inputArtifactFormat(path: String) -> String {
        switch URL(filePath: path).pathExtension.lowercased() {
        case "gds", "gdsii": ArtifactFormat.gdsii.rawValue
        case "oas", "oasis": ArtifactFormat.oasis.rawValue
        case "sp", "cir", "spice", "net": ArtifactFormat.spice.rawValue
        case "spef": ArtifactFormat.spef.rawValue
        case "txt", "log": ArtifactFormat.text.rawValue
        default: ArtifactFormat.json.rawValue
        }
    }

    private func candidateActions(hasMetricReport: Bool) -> [PEXMetricRecoveryCandidateAction] {
        let gates = verificationGates(hasMetricReport: hasMetricReport)
        var requiredInputRefs = ["pex-summary", "layout-ref", "source-netlist-ref"]
        if hasMetricReport {
            requiredInputRefs.insert("post-layout-metric-report", at: 1)
        }
        return [
            PEXMetricRecoveryCandidateAction(
                actionID: "pex-metric-recovery-objective",
                operationID: "pex.metric-recovery-objective",
                maturity: "implemented",
                requiredInputRefs: requiredInputRefs,
                producedArtifacts: ["planning-problem", "pex-metric-recovery-planning-problem"],
                verificationGates: gates,
                rationale: "Use PEX summary, parasitic comparison, and post-layout metric evidence to bound recovery planning."
            ),
        ]
    }

    private func verificationGates(hasMetricReport: Bool) -> [String] {
        var gates = ["schema-validation", "pex-summary-gate", "artifact-integrity"]
        if hasMetricReport {
            gates.append("simulation-metric-gate")
        }
        return gates
    }

    private func isPassingStatus(_ status: String) -> Bool {
        ["passed", "pass", "satisfied", "clean", "success"].contains(status.lowercased())
    }

    private func stableID(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "pex-objective" : collapsed
    }
}
