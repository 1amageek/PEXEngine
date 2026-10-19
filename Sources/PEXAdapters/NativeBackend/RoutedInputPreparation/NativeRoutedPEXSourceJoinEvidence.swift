import CircuiteFoundation
import PEXCore

/// Replayable source join observations; decoding does not grant proof or extraction authority.
public struct NativeRoutedPEXSourceJoinEvidence: Sendable, Codable {
    public struct Net: Sendable, Codable {
        public let defNetName: String
        public let canonicalSourceNetName: String
        public let terminalNames: [String]
    }
    public let topCell: String
    public let defArtifactID: ArtifactID
    public let sourceNetlistArtifactID: ArtifactID
    public let instanceCount: Int
    public let nets: [Net]
}
