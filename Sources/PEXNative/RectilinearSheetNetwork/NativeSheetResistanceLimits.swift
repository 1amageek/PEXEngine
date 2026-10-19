/// Mandatory finite ceilings for one standalone resistance calculation.
public struct NativeSheetResistanceLimits: Sendable, Equatable {
    public let maximumInputRecords: Int
    public let maximumStringBytes: Int
    public let maximumContributorIndices: Int
    public let maximumCoordinateValues: Int
    public let maximumMeshCells: Int
    public let maximumGraphNodes: Int
    public let maximumGraphElements: Int
    public let maximumWorkVisits: Int
    public init(maximumInputRecords: Int, maximumStringBytes: Int, maximumContributorIndices: Int,
                maximumCoordinateValues: Int, maximumMeshCells: Int, maximumGraphNodes: Int,
                maximumGraphElements: Int, maximumWorkVisits: Int) {
        self.maximumInputRecords = maximumInputRecords; self.maximumStringBytes = maximumStringBytes
        self.maximumContributorIndices = maximumContributorIndices; self.maximumCoordinateValues = maximumCoordinateValues
        self.maximumMeshCells = maximumMeshCells; self.maximumGraphNodes = maximumGraphNodes
        self.maximumGraphElements = maximumGraphElements; self.maximumWorkVisits = maximumWorkVisits
    }
    var ceilings: [NativeConductorResource: Int] {
        [.inputRecords: maximumInputRecords, .stringBytes: maximumStringBytes,
         .contributorIndices: maximumContributorIndices, .coordinateValues: maximumCoordinateValues,
         .meshCells: maximumMeshCells, .graphNodes: maximumGraphNodes,
         .graphElements: maximumGraphElements, .workVisits: maximumWorkVisits]
    }
}
