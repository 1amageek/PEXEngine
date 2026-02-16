public struct PEXRunMetrics: Sendable, Codable, Hashable {
    public let totalDurationSeconds: Double
    public let cornerCount: Int
    public let successCount: Int
    public let failureCount: Int

    public init(
        totalDurationSeconds: Double,
        cornerCount: Int,
        successCount: Int,
        failureCount: Int
    ) {
        self.totalDurationSeconds = totalDurationSeconds
        self.cornerCount = cornerCount
        self.successCount = successCount
        self.failureCount = failureCount
    }
}
