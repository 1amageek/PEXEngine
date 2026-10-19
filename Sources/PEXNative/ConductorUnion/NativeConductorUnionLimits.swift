public struct NativeConductorUnionLimits: Sendable, Hashable {
    public let maximumInputRecords: Int
    public let maximumStringBytes: Int
    public let maximumUnionBands: Int
    public let maximumBoundarySegments: Int
    public let maximumContributorIndices: Int
    public let maximumCoordinateValues: Int
    public let maximumWorkVisits: Int
    public init(maximumInputRecords: Int, maximumStringBytes: Int, maximumUnionBands: Int,
                maximumBoundarySegments: Int, maximumContributorIndices: Int,
                maximumCoordinateValues: Int, maximumWorkVisits: Int) {
        self.maximumInputRecords = maximumInputRecords; self.maximumStringBytes = maximumStringBytes
        self.maximumUnionBands = maximumUnionBands; self.maximumBoundarySegments = maximumBoundarySegments
        self.maximumContributorIndices = maximumContributorIndices; self.maximumCoordinateValues = maximumCoordinateValues
        self.maximumWorkVisits = maximumWorkVisits
    }
}
