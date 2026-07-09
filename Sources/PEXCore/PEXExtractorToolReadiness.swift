public struct PEXExtractorToolReadiness: Sendable, Codable, Hashable {
    public let backendID: String
    public let status: PEXExtractorReadinessStatus
    public let reason: String
    public let executablePath: String?
    public let processProfile: PEXProcessProfileReference?
    public let capabilities: PEXBackendCapabilities?
    public let diagnostics: [PEXExtractorDiagnostic]
    public let suggestedActions: [String]

    public init(
        backendID: String,
        status: PEXExtractorReadinessStatus,
        reason: String,
        executablePath: String? = nil,
        processProfile: PEXProcessProfileReference? = nil,
        capabilities: PEXBackendCapabilities? = nil,
        diagnostics: [PEXExtractorDiagnostic] = [],
        suggestedActions: [String] = []
    ) {
        self.backendID = backendID
        self.status = status
        self.reason = reason
        self.executablePath = executablePath
        self.processProfile = processProfile
        self.capabilities = capabilities
        self.diagnostics = diagnostics
        self.suggestedActions = suggestedActions.filter { !$0.isEmpty }
    }
}
