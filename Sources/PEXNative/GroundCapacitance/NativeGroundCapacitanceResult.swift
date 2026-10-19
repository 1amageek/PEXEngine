import PEXCore

/// Spatial scalar contributions over the exact checked union, before numerical-mesh attachment.
public struct NativeGroundCapacitanceResult: Sendable {
    public struct BandAreaContribution: Sendable, Equatable {
        public let bandIndex: Int
        public let farads: Double
        public let contributorIndices: [Int]
    }
    public struct BoundaryContribution: Sendable, Equatable {
        public let boundaryIndex: Int
        public let farads: Double
        public let contributorIndices: [Int]
    }
    public let union: NativeConductorUnion
    public let model: PEXRoutedGroundCapacitanceModel
    public let bandAreaContributions: [BandAreaContribution]
    public let boundaryContributions: [BoundaryContribution]
    public let totalFarads: Double
    public let workVisitsConsumed: Int
    public let inputRecordsConsumed: Int
    public let stringBytesConsumed: Int
    public let outputRecordsConsumed: Int
}
