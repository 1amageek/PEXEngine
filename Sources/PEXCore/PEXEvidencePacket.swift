public struct PEXEvidencePacket: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let packetID: String
    public let domain: String
    public let subject: PEXEvidenceSubject
    public let intent: PEXEvidenceIntent
    public let inputs: [PEXEvidenceArtifactRef]
    public let readiness: [PEXEvidenceReadiness]
    public let artifacts: [PEXEvidenceArtifactRef]
    public let normalizedViews: [PEXEvidenceNormalizedView]
    public let metrics: [PEXEvidenceMetric]
    public let diagnostics: [PEXEvidenceDiagnostic]
    public let failureClassifications: [PEXFailureDiagnosticClassification]
    public let confidence: PEXEvidenceConfidence
    public let decisionHints: [PEXEvidenceDecisionHint]
    public let coverageTags: [String]
    public let relatedEvidenceIDs: [String]

    public init(
        schemaVersion: Int = PEXEvidencePacket.currentSchemaVersion,
        packetID: String,
        domain: String,
        subject: PEXEvidenceSubject,
        intent: PEXEvidenceIntent,
        inputs: [PEXEvidenceArtifactRef] = [],
        readiness: [PEXEvidenceReadiness] = [],
        artifacts: [PEXEvidenceArtifactRef] = [],
        normalizedViews: [PEXEvidenceNormalizedView] = [],
        metrics: [PEXEvidenceMetric] = [],
        diagnostics: [PEXEvidenceDiagnostic] = [],
        failureClassifications: [PEXFailureDiagnosticClassification] = [],
        confidence: PEXEvidenceConfidence,
        decisionHints: [PEXEvidenceDecisionHint] = [],
        coverageTags: [String] = [],
        relatedEvidenceIDs: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.packetID = packetID
        self.domain = domain
        self.subject = subject
        self.intent = intent
        self.inputs = inputs
        self.readiness = readiness
        self.artifacts = artifacts
        self.normalizedViews = normalizedViews
        self.metrics = metrics
        self.diagnostics = diagnostics
        self.failureClassifications = failureClassifications
        self.confidence = confidence
        self.decisionHints = decisionHints
        self.coverageTags = Array(Set(coverageTags.filter { !$0.isEmpty })).sorted()
        self.relatedEvidenceIDs = Array(Set(relatedEvidenceIDs.filter { !$0.isEmpty })).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case packetID
        case domain
        case subject
        case intent
        case inputs
        case readiness
        case artifacts
        case normalizedViews
        case metrics
        case diagnostics
        case failureClassifications
        case confidence
        case decisionHints
        case coverageTags
        case relatedEvidenceIDs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported PEX evidence packet schema version: \(schemaVersion)."
            )
        }
        let failureClassifications = try container.decode(
            [PEXFailureDiagnosticClassification].self,
            forKey: .failureClassifications
        )
        self.init(
            schemaVersion: schemaVersion,
            packetID: try container.decode(String.self, forKey: .packetID),
            domain: try container.decode(String.self, forKey: .domain),
            subject: try container.decode(PEXEvidenceSubject.self, forKey: .subject),
            intent: try container.decode(PEXEvidenceIntent.self, forKey: .intent),
            inputs: try container.decode([PEXEvidenceArtifactRef].self, forKey: .inputs),
            readiness: try container.decode([PEXEvidenceReadiness].self, forKey: .readiness),
            artifacts: try container.decode([PEXEvidenceArtifactRef].self, forKey: .artifacts),
            normalizedViews: try container.decode(
                [PEXEvidenceNormalizedView].self,
                forKey: .normalizedViews
            ),
            metrics: try container.decode([PEXEvidenceMetric].self, forKey: .metrics),
            diagnostics: try container.decode([PEXEvidenceDiagnostic].self, forKey: .diagnostics),
            failureClassifications: failureClassifications.map(Self.normalizedFailureClassification),
            confidence: try container.decode(PEXEvidenceConfidence.self, forKey: .confidence),
            decisionHints: try container.decode([PEXEvidenceDecisionHint].self, forKey: .decisionHints),
            coverageTags: try container.decode([String].self, forKey: .coverageTags),
            relatedEvidenceIDs: try container.decode([String].self, forKey: .relatedEvidenceIDs)
        )
    }

    private static func normalizedFailureClassification(
        _ classification: PEXFailureDiagnosticClassification
    ) -> PEXFailureDiagnosticClassification {
        PEXFailureDiagnosticClassification(
            classificationID: classification.classificationID,
            failureClass: classification.failureClass,
            severity: classification.severity,
            reasonCodes: classification.reasonCodes,
            backendID: classification.backendID,
            processProfileID: classification.processProfileID,
            caseIDs: classification.caseIDs,
            cornerIDs: classification.cornerIDs,
            metricIDs: classification.metricIDs,
            diagnosticIDs: classification.diagnosticIDs,
            artifactIDs: classification.artifactIDs,
            suggestedActions: classification.suggestedActions
        )
    }
}

public struct PEXEvidenceSubject: Sendable, Hashable, Codable {
    public let kind: String
    public let identifier: String
    public let sourceRepository: String?
    public let pinnedRevision: String?
    public let backendID: String?

    public init(
        kind: String,
        identifier: String,
        sourceRepository: String? = nil,
        pinnedRevision: String? = nil,
        backendID: String? = nil
    ) {
        self.kind = kind
        self.identifier = identifier
        self.sourceRepository = sourceRepository
        self.pinnedRevision = pinnedRevision
        self.backendID = backendID
    }
}

public struct PEXEvidenceIntent: Sendable, Hashable, Codable {
    public let summary: String
    public let designContext: String?
    public let cornerIDs: [String]
    public let targetNets: [String]
    public let requestedObservations: [String]

    public init(
        summary: String,
        designContext: String? = nil,
        cornerIDs: [String] = [],
        targetNets: [String] = [],
        requestedObservations: [String] = []
    ) {
        self.summary = summary
        self.designContext = designContext
        self.cornerIDs = Array(Set(cornerIDs.filter { !$0.isEmpty })).sorted()
        self.targetNets = Array(Set(targetNets.filter { !$0.isEmpty })).sorted()
        self.requestedObservations = Array(Set(requestedObservations.filter { !$0.isEmpty })).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case designContext
        case cornerIDs
        case targetNets
        case requestedObservations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            summary: try container.decode(String.self, forKey: .summary),
            designContext: try container.decodeIfPresent(String.self, forKey: .designContext),
            cornerIDs: try container.decode([String].self, forKey: .cornerIDs),
            targetNets: try container.decode([String].self, forKey: .targetNets),
            requestedObservations: try container.decode(
                [String].self,
                forKey: .requestedObservations
            )
        )
    }
}

public struct PEXEvidenceArtifactRef: Sendable, Hashable, Codable {
    public let artifactID: String
    public let path: String
    public let role: String
    public let kind: String
    public let format: String
    public let sha256: String?
    public let byteCount: Int?
    public let cornerID: String?

    public init(
        artifactID: String,
        path: String,
        role: String,
        kind: String,
        format: String,
        sha256: String? = nil,
        byteCount: Int? = nil,
        cornerID: String? = nil
    ) {
        self.artifactID = artifactID
        self.path = path
        self.role = role
        self.kind = kind
        self.format = format
        self.sha256 = sha256
        self.byteCount = byteCount
        self.cornerID = cornerID
    }
}

public enum PEXEvidenceReadinessStatus: String, Sendable, Hashable, Codable {
    case ready
    case blocked
    case unknown
}

public struct PEXEvidenceReadiness: Sendable, Hashable, Codable {
    public let component: String
    public let status: PEXEvidenceReadinessStatus
    public let reason: String
    public let artifactIDs: [String]
    public let suggestedActions: [String]

    public init(
        component: String,
        status: PEXEvidenceReadinessStatus,
        reason: String,
        artifactIDs: [String] = [],
        suggestedActions: [String] = []
    ) {
        self.component = component
        self.status = status
        self.reason = reason
        self.artifactIDs = Array(Set(artifactIDs.filter { !$0.isEmpty })).sorted()
        self.suggestedActions = suggestedActions.filter { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case component
        case status
        case reason
        case artifactIDs
        case suggestedActions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            component: try container.decode(String.self, forKey: .component),
            status: try container.decode(PEXEvidenceReadinessStatus.self, forKey: .status),
            reason: try container.decode(String.self, forKey: .reason),
            artifactIDs: try container.decode([String].self, forKey: .artifactIDs),
            suggestedActions: try container.decode([String].self, forKey: .suggestedActions)
        )
    }
}

public struct PEXEvidenceNormalizedView: Sendable, Hashable, Codable {
    public let viewID: String
    public let kind: String
    public let scope: String
    public let unitSystem: String?
    public let summaryMetrics: [String: Double]
    public let summaryCounts: [String: Int]
    public let sourceArtifactIDs: [String]

    public init(
        viewID: String,
        kind: String,
        scope: String,
        unitSystem: String? = nil,
        summaryMetrics: [String: Double] = [:],
        summaryCounts: [String: Int] = [:],
        sourceArtifactIDs: [String] = []
    ) {
        self.viewID = viewID
        self.kind = kind
        self.scope = scope
        self.unitSystem = unitSystem
        self.summaryMetrics = summaryMetrics
        self.summaryCounts = summaryCounts
        self.sourceArtifactIDs = Array(Set(sourceArtifactIDs.filter { !$0.isEmpty })).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case viewID
        case kind
        case scope
        case unitSystem
        case summaryMetrics
        case summaryCounts
        case sourceArtifactIDs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            viewID: try container.decode(String.self, forKey: .viewID),
            kind: try container.decode(String.self, forKey: .kind),
            scope: try container.decode(String.self, forKey: .scope),
            unitSystem: try container.decodeIfPresent(String.self, forKey: .unitSystem),
            summaryMetrics: try container.decode(
                [String: Double].self,
                forKey: .summaryMetrics
            ),
            summaryCounts: try container.decode([String: Int].self, forKey: .summaryCounts),
            sourceArtifactIDs: try container.decode([String].self, forKey: .sourceArtifactIDs)
        )
    }
}

public struct PEXEvidenceMetric: Sendable, Hashable, Codable {
    public let name: String
    public let value: Double
    public let unit: String?
    public let scope: String
    public let caseID: String?
    public let cornerID: String?
    public let netName: String?
    public let expectedValue: Double?
    public let tolerance: Double?
    public let sourceArtifactID: String?

    public init(
        name: String,
        value: Double,
        unit: String? = nil,
        scope: String,
        caseID: String? = nil,
        cornerID: String? = nil,
        netName: String? = nil,
        expectedValue: Double? = nil,
        tolerance: Double? = nil,
        sourceArtifactID: String? = nil
    ) {
        self.name = name
        self.value = value
        self.unit = unit
        self.scope = scope
        self.caseID = caseID
        self.cornerID = cornerID
        self.netName = netName
        self.expectedValue = expectedValue
        self.tolerance = tolerance
        self.sourceArtifactID = sourceArtifactID
    }
}

public enum PEXEvidenceSeverity: String, Sendable, Hashable, Codable {
    case info
    case warning
    case error
    case blocked
}

public struct PEXEvidenceDiagnostic: Sendable, Hashable, Codable {
    public let diagnosticID: String
    public let code: String
    public let category: String
    public let severity: PEXEvidenceSeverity
    public let message: String
    public let caseID: String?
    public let observedText: String?
    public let expectedText: String?
    public let observedValue: Double?
    public let expectedValue: Double?
    public let tolerance: Double?
    public let artifactIDs: [String]
    public let suggestedActions: [String]

    public init(
        diagnosticID: String,
        code: String,
        category: String,
        severity: PEXEvidenceSeverity,
        message: String,
        caseID: String? = nil,
        observedText: String? = nil,
        expectedText: String? = nil,
        observedValue: Double? = nil,
        expectedValue: Double? = nil,
        tolerance: Double? = nil,
        artifactIDs: [String] = [],
        suggestedActions: [String] = []
    ) {
        self.diagnosticID = diagnosticID
        self.code = code
        self.category = category
        self.severity = severity
        self.message = message
        self.caseID = caseID
        self.observedText = observedText
        self.expectedText = expectedText
        self.observedValue = observedValue
        self.expectedValue = expectedValue
        self.tolerance = tolerance
        self.artifactIDs = Array(Set(artifactIDs.filter { !$0.isEmpty })).sorted()
        self.suggestedActions = suggestedActions.filter { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case diagnosticID
        case code
        case category
        case severity
        case message
        case caseID
        case observedText
        case expectedText
        case observedValue
        case expectedValue
        case tolerance
        case artifactIDs
        case suggestedActions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            diagnosticID: try container.decode(String.self, forKey: .diagnosticID),
            code: try container.decode(String.self, forKey: .code),
            category: try container.decode(String.self, forKey: .category),
            severity: try container.decode(PEXEvidenceSeverity.self, forKey: .severity),
            message: try container.decode(String.self, forKey: .message),
            caseID: try container.decodeIfPresent(String.self, forKey: .caseID),
            observedText: try container.decodeIfPresent(String.self, forKey: .observedText),
            expectedText: try container.decodeIfPresent(String.self, forKey: .expectedText),
            observedValue: try container.decodeIfPresent(Double.self, forKey: .observedValue),
            expectedValue: try container.decodeIfPresent(Double.self, forKey: .expectedValue),
            tolerance: try container.decodeIfPresent(Double.self, forKey: .tolerance),
            artifactIDs: try container.decode([String].self, forKey: .artifactIDs),
            suggestedActions: try container.decode([String].self, forKey: .suggestedActions)
        )
    }
}

public enum PEXEvidenceConfidenceLevel: String, Sendable, Hashable, Codable {
    case high
    case medium
    case low
    case unknown
}

public struct PEXEvidenceConfidence: Sendable, Hashable, Codable {
    public let level: PEXEvidenceConfidenceLevel
    public let rationale: String
    public let strengths: [String]
    public let uncertainties: [String]

    public init(
        level: PEXEvidenceConfidenceLevel,
        rationale: String,
        strengths: [String] = [],
        uncertainties: [String] = []
    ) {
        self.level = level
        self.rationale = rationale
        self.strengths = Array(Set(strengths.filter { !$0.isEmpty })).sorted()
        self.uncertainties = Array(Set(uncertainties.filter { !$0.isEmpty })).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case level
        case rationale
        case strengths
        case uncertainties
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            level: try container.decode(PEXEvidenceConfidenceLevel.self, forKey: .level),
            rationale: try container.decode(String.self, forKey: .rationale),
            strengths: try container.decode([String].self, forKey: .strengths),
            uncertainties: try container.decode([String].self, forKey: .uncertainties)
        )
    }
}

public enum PEXEvidenceDecisionPriority: String, Sendable, Hashable, Codable {
    case immediate
    case high
    case normal
    case low
}

public struct PEXEvidenceDecisionHint: Sendable, Hashable, Codable {
    public let hintID: String
    public let priority: PEXEvidenceDecisionPriority
    public let action: String
    public let rationale: String
    public let relatedDiagnosticIDs: [String]
    public let artifactIDs: [String]

    public init(
        hintID: String,
        priority: PEXEvidenceDecisionPriority,
        action: String,
        rationale: String,
        relatedDiagnosticIDs: [String] = [],
        artifactIDs: [String] = []
    ) {
        self.hintID = hintID
        self.priority = priority
        self.action = action
        self.rationale = rationale
        self.relatedDiagnosticIDs = Array(Set(relatedDiagnosticIDs.filter { !$0.isEmpty })).sorted()
        self.artifactIDs = Array(Set(artifactIDs.filter { !$0.isEmpty })).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case hintID
        case priority
        case action
        case rationale
        case relatedDiagnosticIDs
        case artifactIDs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hintID: try container.decode(String.self, forKey: .hintID),
            priority: try container.decode(PEXEvidenceDecisionPriority.self, forKey: .priority),
            action: try container.decode(String.self, forKey: .action),
            rationale: try container.decode(String.self, forKey: .rationale),
            relatedDiagnosticIDs: try container.decode(
                [String].self,
                forKey: .relatedDiagnosticIDs
            ),
            artifactIDs: try container.decode([String].self, forKey: .artifactIDs)
        )
    }
}
