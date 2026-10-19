import CircuiteFoundation
import PEXCore

/// Checked exact conductor coverage. Source declarations alone do not construct it.
public struct NativeConductorUnion: Sendable {
    public struct Rect: Sendable, Hashable {
        public let minX: Int32, minY: Int32, maxX: Int32, maxY: Int32
        public init(minX: Int32, minY: Int32, maxX: Int32, maxY: Int32) {
            self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
        }
    }
    public struct SourceFact: Sendable, Hashable {
        public let artifactID: ArtifactID
        public let byteRange: PEXOpenRCXSourceModel.SourceRange
        public init(artifactID: ArtifactID, byteRange: PEXOpenRCXSourceModel.SourceRange) {
            self.artifactID = artifactID; self.byteRange = byteRange
        }
    }
    public struct Source: Sendable, Hashable {
        public let sourceID: String
        public let netName: NetName
        public let layerName: String
        public let rect: Rect
        public let sourceFacts: [SourceFact]
        public init(sourceID: String, netName: NetName, layerName: String, rect: Rect, sourceFacts: [SourceFact]) {
            self.sourceID = sourceID; self.netName = netName; self.layerName = layerName
            self.rect = rect; self.sourceFacts = sourceFacts
        }
    }
    public struct Band: Sendable, Hashable {
        public let netName: NetName
        public let layerName: String
        public let rect: Rect
        public let contributorIndices: [Int]
    }
    public struct Boundary: Sendable, Hashable {
        public enum Side: String, Sendable, Hashable { case minX, maxX, minY, maxY }
        public let netName: NetName
        public let layerName: String
        public let side: Side
        public let coordinate: Int32
        public let begin: Int32
        public let end: Int32
        public let bandIndex: Int
        public let contributorIndices: [Int]
    }
    public let databaseUnitsPerMicron: Int64
    public let sources: [Source]
    public let bands: [Band]
    public let boundaries: [Boundary]

    init(databaseUnitsPerMicron: Int64, sources: [Source], bands: [Band], boundaries: [Boundary]) {
        self.databaseUnitsPerMicron = databaseUnitsPerMicron; self.sources = sources
        self.bands = bands; self.boundaries = boundaries
    }
}
