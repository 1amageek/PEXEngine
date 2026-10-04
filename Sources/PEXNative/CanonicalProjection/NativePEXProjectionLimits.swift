public struct NativePEXProjectionLimits: Sendable, Equatable, Codable {
    /// Bounds inspected collection records and identifier UTF-8 bytes.
    public let maximumInputRecords: Int
    public let maximumNodes: Int
    public let maximumElements: Int
    public let maximumWorkVisits: Int
    public static let `default` = Self()

    public init(maximumInputRecords: Int = 4_000_000, maximumNodes: Int = 1_000_000,
                maximumElements: Int = 4_000_000, maximumWorkVisits: Int = 16_000_000) {
        self.maximumInputRecords = maximumInputRecords; self.maximumNodes = maximumNodes
        self.maximumElements = maximumElements; self.maximumWorkVisits = maximumWorkVisits
    }
}
