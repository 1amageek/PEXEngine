/// Host projection ceilings; these do not measure opaque codec allocations or process RSS.
public struct NativeRoutedPEXPreparationLimits: Sendable, Codable, Hashable {
    public let maximumSourceBytes: Int
    public let maximumTotalSourceBytes: UInt64
    public let maximumRecords: Int
    public let maximumStringBytes: Int
    public let maximumWorkVisits: Int
    public let maximumNetlistManagedStorageBytes: UInt64
    public let maximumNetlistAllocationBytes: UInt64

    public init(maximumSourceBytes: Int, maximumTotalSourceBytes: UInt64, maximumRecords: Int, maximumStringBytes: Int, maximumWorkVisits: Int, maximumNetlistManagedStorageBytes: UInt64, maximumNetlistAllocationBytes: UInt64) {
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumTotalSourceBytes = maximumTotalSourceBytes
        self.maximumRecords = maximumRecords
        self.maximumStringBytes = maximumStringBytes
        self.maximumWorkVisits = maximumWorkVisits
        self.maximumNetlistManagedStorageBytes = maximumNetlistManagedStorageBytes
        self.maximumNetlistAllocationBytes = maximumNetlistAllocationBytes
    }
}
