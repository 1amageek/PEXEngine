public enum PEXExtractorDiagnosticSeverity: String, Sendable, Codable, Hashable {
    case info
    case warning
    case error
    case blocked
}

public struct PEXExtractorDiagnostic: Sendable, Codable, Hashable {
    public let diagnosticID: String
    public let code: String
    public let severity: PEXExtractorDiagnosticSeverity
    public let message: String
    public let suggestedActions: [String]

    public init(
        diagnosticID: String,
        code: String,
        severity: PEXExtractorDiagnosticSeverity,
        message: String,
        suggestedActions: [String] = []
    ) {
        self.diagnosticID = diagnosticID
        self.code = code
        self.severity = severity
        self.message = message
        self.suggestedActions = suggestedActions.filter { !$0.isEmpty }
    }
}
