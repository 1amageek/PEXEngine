import CircuiteFoundation
import Foundation

public enum PEXArtifactRecordError: Error, Sendable, Equatable {
    case availableDescriptorMismatch
    case availablePathMismatch
}

public struct PEXArtifactRecord: Sendable, Codable, Hashable, Identifiable {
    public let declaration: PEXArtifactDeclaration
    public let payload: PEXArtifactPayload
    public let stage: PEXStage
    public let cornerID: PEXCornerID?
    public let createdAt: Date
    public let provenance: PEXArtifactProvenance?

    public var id: PEXArtifactRecordID { declaration.id }
    public var descriptor: ArtifactDescriptor { declaration.descriptor }
    public var relativePath: ArtifactRelativePath { declaration.relativePath }
    public var availability: PEXArtifactAvailability { payload.availability }
    public var reference: ArtifactReference? { payload.reference }
    public var artifactAvailability: ArtifactAvailability? { payload.artifactAvailability }
    public var producer: ProducerIdentity? { payload.producer }

    public init(
        declaration: PEXArtifactDeclaration,
        payload: PEXArtifactPayload,
        stage: PEXStage,
        cornerID: PEXCornerID? = nil,
        createdAt: Date = Date(),
        provenance: PEXArtifactProvenance? = nil
    ) throws {
        if case .available(let artifact) = payload {
            guard artifact.reference.descriptor == declaration.descriptor else {
                throw PEXArtifactRecordError.availableDescriptorMismatch
            }
            guard case .local(_, _, let relativePath) = artifact.availability,
                  relativePath == declaration.relativePath else {
                throw PEXArtifactRecordError.availablePathMismatch
            }
        }
        self.declaration = declaration
        self.payload = payload
        self.stage = stage
        self.cornerID = cornerID
        self.createdAt = createdAt
        self.provenance = provenance
    }

    public func matches(kind: PEXArtifactKind) -> Bool {
        descriptor.kind.rawValue == kind.foundationRawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            declaration: container.decode(PEXArtifactDeclaration.self, forKey: .declaration),
            payload: container.decode(PEXArtifactPayload.self, forKey: .payload),
            stage: container.decode(PEXStage.self, forKey: .stage),
            cornerID: container.decodeIfPresent(PEXCornerID.self, forKey: .cornerID),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            provenance: container.decodeIfPresent(PEXArtifactProvenance.self, forKey: .provenance)
        )
    }
}
