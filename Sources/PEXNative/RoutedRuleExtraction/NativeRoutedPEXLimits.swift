public struct NativeRoutedPEXLimits: Sendable, Codable, Hashable {
    public let maximumInputRecords: Int
    public let maximumStringBytes: Int
    public let maximumSourceRecords: Int
    public let maximumWorkVisits: Int
    public let maximumTrackEntries: Int
    public let maximumCoordinateValues: Int
    public let maximumGraphNodes: Int
    public let maximumGraphElements: Int
    public let maximumQueryReceipts: Int
    public init(maximumInputRecords: Int, maximumStringBytes: Int, maximumSourceRecords: Int,
                maximumWorkVisits: Int, maximumTrackEntries: Int, maximumCoordinateValues: Int,
                maximumGraphNodes: Int, maximumGraphElements: Int, maximumQueryReceipts: Int) {
        self.maximumInputRecords = maximumInputRecords; self.maximumStringBytes = maximumStringBytes
        self.maximumSourceRecords = maximumSourceRecords; self.maximumWorkVisits = maximumWorkVisits
        self.maximumTrackEntries = maximumTrackEntries; self.maximumCoordinateValues = maximumCoordinateValues
        self.maximumGraphNodes = maximumGraphNodes; self.maximumGraphElements = maximumGraphElements
        self.maximumQueryReceipts = maximumQueryReceipts
    }
}
