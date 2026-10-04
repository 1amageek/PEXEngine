import Foundation
import CircuiteFoundation

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

