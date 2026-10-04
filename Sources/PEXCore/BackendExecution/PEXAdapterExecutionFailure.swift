public struct PEXAdapterExecutionFailure: Error, Sendable {
    public let failureKind: PEXErrorKind?
    public let message: String
    public let stage: PEXStage
    public let cornerID: PEXCornerID?
    public let generatedArtifacts: [PEXGeneratedArtifact]
    public let underlyingDescription: String?
    public let executionIdentity: PEXBackendExecutionIdentity?

    public init(
        message: String,
        stage: PEXStage,
        cornerID: PEXCornerID? = nil,
        failureKind: PEXErrorKind? = nil,
        generatedArtifacts: [PEXGeneratedArtifact] = [],
        executionIdentity: PEXBackendExecutionIdentity? = nil,
        underlying: (any Error)? = nil
    ) {
        self.message = message
        self.stage = stage
        self.cornerID = cornerID
        self.failureKind = failureKind
        self.generatedArtifacts = generatedArtifacts
        self.executionIdentity = executionIdentity
        self.underlyingDescription = underlying.map { String(describing: $0) }
    }
}
