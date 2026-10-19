import CircuiteFoundation

/// Exact source roles for routed-native preparation; declared references alone grant no extraction authority.
public struct PEXRoutedInputSources: Sendable, Codable, Hashable {
    public let expectedDEF: ArtifactReference
    public let expectedSourceNetlist: ArtifactReference
    public let routedTechnologyLEF: ArtifactReference
    public let standardCellLEFs: [ArtifactReference]
    public let corners: [PEXRoutedCornerSource]

    public init(expectedDEF: ArtifactReference, expectedSourceNetlist: ArtifactReference, routedTechnologyLEF: ArtifactReference,
                standardCellLEFs: [ArtifactReference], corners: [PEXRoutedCornerSource]) {
        self.expectedDEF = expectedDEF; self.expectedSourceNetlist = expectedSourceNetlist
        self.routedTechnologyLEF = routedTechnologyLEF
        self.standardCellLEFs = standardCellLEFs; self.corners = corners
    }
}
