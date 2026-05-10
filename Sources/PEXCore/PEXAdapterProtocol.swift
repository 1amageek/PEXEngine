import Foundation

public protocol PEXAdapter: Sendable {
    var backendID: String { get }
    var capabilities: PEXBackendCapabilities { get }
    func prepare(_ context: PEXExecutionContext) async throws
    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult
    func cleanup(_ context: PEXExecutionContext) async
}

public struct PEXGeneratedArtifact: Sendable, Codable, Hashable {
    public let kind: PEXArtifactKind
    public let stage: PEXStage
    public let cornerID: PEXCornerID?
    public let url: URL
    public let status: PEXArtifactStatus
    public let provenance: PEXArtifactProvenance?

    public init(
        kind: PEXArtifactKind,
        stage: PEXStage,
        cornerID: PEXCornerID? = nil,
        url: URL,
        status: PEXArtifactStatus = .available,
        provenance: PEXArtifactProvenance? = nil
    ) {
        self.kind = kind
        self.stage = stage
        self.cornerID = cornerID
        self.url = url
        self.status = status
        self.provenance = provenance
    }
}

public struct PEXAdapterExecutionResult: Sendable, Codable, Hashable {
    public let rawOutput: PEXRawOutput
    public let generatedArtifacts: [PEXGeneratedArtifact]

    public init(rawOutput: PEXRawOutput, generatedArtifacts: [PEXGeneratedArtifact]) {
        self.rawOutput = rawOutput
        self.generatedArtifacts = generatedArtifacts
    }
}

public struct PEXAdapterExecutionFailure: Error, Sendable {
    public let message: String
    public let stage: PEXStage
    public let cornerID: PEXCornerID?
    public let generatedArtifacts: [PEXGeneratedArtifact]
    public let underlyingDescription: String?

    public init(
        message: String,
        stage: PEXStage,
        cornerID: PEXCornerID? = nil,
        generatedArtifacts: [PEXGeneratedArtifact] = [],
        underlying: (any Error)? = nil
    ) {
        self.message = message
        self.stage = stage
        self.cornerID = cornerID
        self.generatedArtifacts = generatedArtifacts
        self.underlyingDescription = underlying.map { String(describing: $0) }
    }
}
