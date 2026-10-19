public struct NativeGroundCapacitanceLimits: Sendable, Codable, Hashable {
    public let maximumInputRecords: Int
    public let maximumStringBytes: Int
    public let maximumOutputRecords: Int
    public let maximumWorkVisits: Int

    public init(maximumInputRecords: Int, maximumStringBytes: Int,
                maximumOutputRecords: Int, maximumWorkVisits: Int) {
        self.maximumInputRecords = maximumInputRecords
        self.maximumStringBytes = maximumStringBytes
        self.maximumOutputRecords = maximumOutputRecords
        self.maximumWorkVisits = maximumWorkVisits
    }
}
