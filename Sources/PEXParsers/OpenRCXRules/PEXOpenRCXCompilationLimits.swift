public struct PEXOpenRCXCompilationLimits: Sendable, Hashable, Codable {
    public let maximumSourceBytes: Int
    public let maximumLineBytes: Int
    public let maximumLines: Int
    public let maximumRecords: Int
    public let maximumRows: Int
    public let maximumWorkVisits: Int
    public init(maximumSourceBytes: Int, maximumLineBytes: Int, maximumLines: Int,
                maximumRecords: Int, maximumRows: Int, maximumWorkVisits: Int) {
        self.maximumSourceBytes = maximumSourceBytes; self.maximumLineBytes = maximumLineBytes
        self.maximumLines = maximumLines; self.maximumRecords = maximumRecords
        self.maximumRows = maximumRows; self.maximumWorkVisits = maximumWorkVisits
    }
}
