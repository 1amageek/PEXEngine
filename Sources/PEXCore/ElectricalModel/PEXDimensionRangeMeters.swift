public struct PEXDimensionRangeMeters: Sendable, Codable, Hashable {
    public let minimumMeters: Double
    public let maximumMeters: Double

    public init(minimumMeters: Double, maximumMeters: Double) {
        self.minimumMeters = minimumMeters
        self.maximumMeters = maximumMeters
    }

    public func requireContains(_ meters: Double, field: String) throws(PEXElectricalModelError) {
        try validate(field: field)
        guard meters.isFinite, meters >= minimumMeters, meters <= maximumMeters else {
            throw .outOfRange(field: field)
        }
    }

    func validate(field: String) throws(PEXElectricalModelError) {
        guard minimumMeters.isFinite, maximumMeters.isFinite,
              minimumMeters > 0, maximumMeters >= minimumMeters else {
            throw .invalidRange(field: field)
        }
    }
}
