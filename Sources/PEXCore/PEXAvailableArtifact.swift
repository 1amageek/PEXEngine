import CircuiteFoundationFoundation

public enum PEXAvailableArtifactError: Error, Sendable, Equatable {
    case availabilityIdentityMismatch
    case descriptorMismatch
}

public struct PEXAvailableArtifact: Sendable, Codable, Hashable {
    public let reference: ArtifactReference
    public let availability: ArtifactAvailability
    public let producer: ProducerIdentity?

    public init(
        reference: ArtifactReference,
        availability: ArtifactAvailability,
        producer: ProducerIdentity? = nil
    ) throws {
        guard availability.artifactID == reference.id else {
            throw PEXAvailableArtifactError.availabilityIdentityMismatch
        }
        self.reference = reference
        self.availability = availability
        self.producer = producer
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            reference: container.decode(ArtifactReference.self, forKey: .reference),
            availability: container.decode(ArtifactAvailability.self, forKey: .availability),
            producer: container.decodeIfPresent(ProducerIdentity.self, forKey: .producer)
        )
    }
}
