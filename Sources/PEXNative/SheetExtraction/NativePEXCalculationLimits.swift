public struct NativePEXCalculationLimits: Sendable, Equatable {
    public let maximumInputRecords: Int
    public let maximumCoordinateValues: Int
    public let maximumMeshCells: Int
    public let maximumNetworkElements: Int
    public let maximumWorkVisits: Int
    public let maximumPinContacts: Int

    public static let `default` = Self()

    public init(maximumInputRecords: Int = 1_000_000, maximumCoordinateValues: Int = 500_000,
                maximumMeshCells: Int = 1_000_000, maximumNetworkElements: Int = 8_000_000,
                maximumWorkVisits: Int = 16_000_000, maximumPinContacts: Int = 1_000_000) {
        self.maximumInputRecords = maximumInputRecords
        self.maximumCoordinateValues = maximumCoordinateValues
        self.maximumMeshCells = maximumMeshCells
        self.maximumNetworkElements = maximumNetworkElements
        self.maximumWorkVisits = maximumWorkVisits
        self.maximumPinContacts = maximumPinContacts
    }
}
