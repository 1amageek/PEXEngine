public enum PEXFailureDiagnosticClass: String, Sendable, Hashable, Codable {
    case missingExtractorReadiness = "missing_extractor_readiness"
    case processProfileError = "process_profile_error"
    case parseFailure = "parse_failure"
    case unitMismatch = "unit_mismatch"
    case physicalBoundMismatch = "physical_bound_mismatch"
    case perCornerFailure = "per_corner_failure"
    case evaluationFailure = "evaluation_failure"
    case externalExtractorFailure = "external_extractor_failure"
}

public struct PEXFailureDiagnosticClassification: Sendable, Hashable, Codable {
    public let classificationID: String
    public let failureClass: PEXFailureDiagnosticClass
    public let severity: PEXEvidenceSeverity
    public let reasonCodes: [String]
    public let backendID: String?
    public let processProfileID: String?
    public let caseIDs: [String]
    public let cornerIDs: [String]
    public let metricIDs: [String]
    public let diagnosticIDs: [String]
    public let artifactIDs: [String]
    public let suggestedActions: [String]

    public init(
        classificationID: String,
        failureClass: PEXFailureDiagnosticClass,
        severity: PEXEvidenceSeverity,
        reasonCodes: [String] = [],
        backendID: String? = nil,
        processProfileID: String? = nil,
        caseIDs: [String] = [],
        cornerIDs: [String] = [],
        metricIDs: [String] = [],
        diagnosticIDs: [String] = [],
        artifactIDs: [String] = [],
        suggestedActions: [String] = []
    ) {
        self.classificationID = classificationID
        self.failureClass = failureClass
        self.severity = severity
        self.reasonCodes = Array(Set(reasonCodes.filter { !$0.isEmpty })).sorted()
        self.backendID = backendID
        self.processProfileID = processProfileID
        self.caseIDs = Array(Set(caseIDs.filter { !$0.isEmpty })).sorted()
        self.cornerIDs = Array(Set(cornerIDs.filter { !$0.isEmpty })).sorted()
        self.metricIDs = Array(Set(metricIDs.filter { !$0.isEmpty })).sorted()
        self.diagnosticIDs = Array(Set(diagnosticIDs.filter { !$0.isEmpty })).sorted()
        self.artifactIDs = Array(Set(artifactIDs.filter { !$0.isEmpty })).sorted()
        self.suggestedActions = Array(Set(suggestedActions.filter { !$0.isEmpty })).sorted()
    }
}
