import Foundation
import CircuiteFoundation

public enum PEXMetricRecoveryInputArtifactError: Error, Sendable, Equatable {
    case emptyLogicalID
    case emptyPath
}

public struct PEXMetricRecoveryInputArtifact: Codable, Sendable, Equatable {
    public let logicalID: String
    public let reference: ArtifactReference
    public let path: String

    public init(
        logicalID: String,
        reference: ArtifactReference,
        path: String
    ) throws {
        guard !logicalID.isEmpty else {
            throw PEXMetricRecoveryInputArtifactError.emptyLogicalID
        }
        guard !path.isEmpty else {
            throw PEXMetricRecoveryInputArtifactError.emptyPath
        }
        self.logicalID = logicalID
        self.reference = reference
        self.path = path
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            logicalID: container.decode(String.self, forKey: .logicalID),
            reference: container.decode(ArtifactReference.self, forKey: .reference),
            path: container.decode(String.self, forKey: .path)
        )
    }
}
