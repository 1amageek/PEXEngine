import Foundation
import CircuiteFoundation

public protocol PEXExtracting: Sendable {
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
    public let availability: PEXArtifactAvailability
    public let provenance: PEXArtifactProvenance?
    public let producer: ProducerIdentity?

    public init(
        kind: PEXArtifactKind,
        stage: PEXStage,
        cornerID: PEXCornerID? = nil,
        url: URL,
        availability: PEXArtifactAvailability = .available,
        provenance: PEXArtifactProvenance? = nil,
        producer: ProducerIdentity? = nil
    ) {
        self.kind = kind
        self.stage = stage
        self.cornerID = cornerID
        self.url = url
        self.availability = availability
        self.provenance = provenance
        self.producer = producer
    }
}

public struct PEXAdapterExecutionResult: Sendable, Codable, Hashable {
    public let rawOutput: PEXRawOutput
    public let generatedArtifacts: [PEXGeneratedArtifact]
    public let executionIdentity: PEXBackendExecutionIdentity

    public init(
        rawOutput: PEXRawOutput,
        generatedArtifacts: [PEXGeneratedArtifact],
        executionIdentity: PEXBackendExecutionIdentity
    ) {
        self.rawOutput = rawOutput
        self.generatedArtifacts = generatedArtifacts
        self.executionIdentity = executionIdentity
    }
}

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
