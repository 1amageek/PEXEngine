import Foundation
import CircuiteFoundation

public struct PEXMetricRecoveryPlanningProblem: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let kind: String
    public let problemID: String
    public let status: String
    public let inputArtifacts: [ArtifactReference]
    public let summary: PEXMetricRecoverySummary
    public let objectives: [PEXMetricRecoveryObjective]
    public let hotspots: [PEXMetricRecoveryHotspot]
    public let candidateActions: [PEXMetricRecoveryCandidateAction]
    public let verificationGates: [String]
    public let diagnostics: [PEXMetricRecoveryDiagnostic]

    public init(
        schemaVersion: Int = 2,
        kind: String = "pex-metric-recovery-planning-problem",
        problemID: String,
        status: String,
        inputArtifacts: [ArtifactReference],
        summary: PEXMetricRecoverySummary,
        objectives: [PEXMetricRecoveryObjective],
        hotspots: [PEXMetricRecoveryHotspot],
        candidateActions: [PEXMetricRecoveryCandidateAction],
        verificationGates: [String],
        diagnostics: [PEXMetricRecoveryDiagnostic]
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.problemID = problemID
        self.status = status
        self.inputArtifacts = inputArtifacts
        self.summary = summary
        self.objectives = objectives
        self.hotspots = hotspots
        self.candidateActions = candidateActions
        self.verificationGates = verificationGates
        self.diagnostics = diagnostics
    }
}

public struct PEXMetricRecoverySummary: Codable, Sendable, Equatable {
    public let objectiveCount: Int
    public let hotspotCount: Int
    public let diagnosticCount: Int
    public let pexSummaryStatus: String
    public let pexCompletenessStatus: String
    public let failedCornerCount: Int
    public let comparisonViolationCount: Int
    public let metricFailureCount: Int
    public let suggestedActionCount: Int

    public init(
        objectiveCount: Int,
        hotspotCount: Int,
        diagnosticCount: Int,
        pexSummaryStatus: String,
        pexCompletenessStatus: String,
        failedCornerCount: Int,
        comparisonViolationCount: Int,
        metricFailureCount: Int,
        suggestedActionCount: Int
    ) {
        self.objectiveCount = objectiveCount
        self.hotspotCount = hotspotCount
        self.diagnosticCount = diagnosticCount
        self.pexSummaryStatus = pexSummaryStatus
        self.pexCompletenessStatus = pexCompletenessStatus
        self.failedCornerCount = failedCornerCount
        self.comparisonViolationCount = comparisonViolationCount
        self.metricFailureCount = metricFailureCount
        self.suggestedActionCount = suggestedActionCount
    }
}

public struct PEXMetricRecoveryObjective: Codable, Sendable, Equatable {
    public let objectiveID: String
    public let domain: String
    public let kind: String
    public let priority: String
    public let target: String
    public let currentValue: Double?
    public let requiredValue: Double?
    public let unit: String?
    public let sourceRefIDs: [String]
    public let description: String
    public let evidence: [PEXMetricRecoveryEvidence]
    public let suggestedActions: [String]

    public init(
        objectiveID: String,
        domain: String,
        kind: String,
        priority: String,
        target: String,
        currentValue: Double? = nil,
        requiredValue: Double? = nil,
        unit: String? = nil,
        sourceRefIDs: [String],
        description: String,
        evidence: [PEXMetricRecoveryEvidence] = [],
        suggestedActions: [String] = []
    ) {
        self.objectiveID = objectiveID
        self.domain = domain
        self.kind = kind
        self.priority = priority
        self.target = target
        self.currentValue = currentValue
        self.requiredValue = requiredValue
        self.unit = unit
        self.sourceRefIDs = sourceRefIDs
        self.description = description
        self.evidence = evidence
        self.suggestedActions = suggestedActions
    }
}

public struct PEXMetricRecoveryEvidence: Codable, Sendable, Equatable {
    public let key: String
    public let stringValue: String?
    public let numericValue: Double?
    public let boolValue: Bool?
    public let stringValues: [String]

    public init(
        key: String,
        stringValue: String? = nil,
        numericValue: Double? = nil,
        boolValue: Bool? = nil,
        stringValues: [String] = []
    ) {
        self.key = key
        self.stringValue = stringValue
        self.numericValue = numericValue
        self.boolValue = boolValue
        self.stringValues = stringValues
    }
}

public struct PEXMetricRecoveryHotspot: Codable, Sendable, Equatable {
    public let hotspotID: String
    public let source: String
    public let cornerID: String?
    public let netName: String?
    public let totalCapacitanceF: Double?
    public let totalResistanceOhm: Double?
    public let relativeCapDelta: Double?
    public let relativeResistanceDelta: Double?
    public let sourceRefIDs: [String]

    public init(
        hotspotID: String,
        source: String,
        cornerID: String? = nil,
        netName: String? = nil,
        totalCapacitanceF: Double? = nil,
        totalResistanceOhm: Double? = nil,
        relativeCapDelta: Double? = nil,
        relativeResistanceDelta: Double? = nil,
        sourceRefIDs: [String]
    ) {
        self.hotspotID = hotspotID
        self.source = source
        self.cornerID = cornerID
        self.netName = netName
        self.totalCapacitanceF = totalCapacitanceF
        self.totalResistanceOhm = totalResistanceOhm
        self.relativeCapDelta = relativeCapDelta
        self.relativeResistanceDelta = relativeResistanceDelta
        self.sourceRefIDs = sourceRefIDs
    }
}

public struct PEXMetricRecoveryCandidateAction: Codable, Sendable, Equatable {
    public let actionID: String
    public let operationID: String
    public let maturity: String
    public let requiredInputRefs: [String]
    public let producedArtifacts: [String]
    public let verificationGates: [String]
    public let rationale: String

    public init(
        actionID: String,
        operationID: String,
        maturity: String,
        requiredInputRefs: [String],
        producedArtifacts: [String],
        verificationGates: [String],
        rationale: String
    ) {
        self.actionID = actionID
        self.operationID = operationID
        self.maturity = maturity
        self.requiredInputRefs = requiredInputRefs
        self.producedArtifacts = producedArtifacts
        self.verificationGates = verificationGates
        self.rationale = rationale
    }
}

public struct PEXMetricRecoveryDiagnostic: Codable, Sendable, Equatable {
    public let severity: String
    public let code: String
    public let message: String
    public let sourceRefID: String?

    public init(severity: String, code: String, message: String, sourceRefID: String? = nil) {
        self.severity = severity
        self.code = code
        self.message = message
        self.sourceRefID = sourceRefID
    }
}
