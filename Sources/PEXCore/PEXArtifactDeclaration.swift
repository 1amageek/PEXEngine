import CircuiteFoundation

public struct PEXArtifactDeclaration: Sendable, Codable, Hashable, Identifiable {
    public let id: PEXArtifactRecordID
    public let descriptor: ArtifactDescriptor
    public let relativePath: ArtifactRelativePath

    public init(
        id: PEXArtifactRecordID,
        descriptor: ArtifactDescriptor,
        relativePath: ArtifactRelativePath
    ) {
        self.id = id
        self.descriptor = descriptor
        self.relativePath = relativePath
    }
}
