public struct NativePEXElectrodeLimits: Sendable, Equatable, Codable {
    /// Bounds inspected collection records and identifier UTF-8 bytes.
    public let maximumInputRecords: Int
    public let maximumFaceRecords: Int
    public let maximumContacts: Int
    public let maximumWorkVisits: Int
    public static let `default` = Self()

    public init(maximumInputRecords: Int = 1_000_000, maximumFaceRecords: Int = 4_000_000,
                maximumContacts: Int = 1_000_000, maximumWorkVisits: Int = 16_000_000) {
        self.maximumInputRecords = maximumInputRecords; self.maximumFaceRecords = maximumFaceRecords
        self.maximumContacts = maximumContacts; self.maximumWorkVisits = maximumWorkVisits
    }
}
