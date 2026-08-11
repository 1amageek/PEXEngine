import CircuiteFoundation

public enum PEXArtifactPayload: Sendable, Codable, Hashable {
    case available(PEXAvailableArtifact)
    case missing
    case omitted

    public var availability: PEXArtifactAvailability {
        switch self {
        case .available: .available
        case .missing: .missing
        case .omitted: .omitted
        }
    }

    public var reference: ArtifactReference? {
        guard case .available(let artifact) = self else { return nil }
        return artifact.reference
    }

    public var artifactAvailability: ArtifactAvailability? {
        guard case .available(let artifact) = self else { return nil }
        return artifact.availability
    }

    public var producer: ProducerIdentity? {
        guard case .available(let artifact) = self else { return nil }
        return artifact.producer
    }
}
