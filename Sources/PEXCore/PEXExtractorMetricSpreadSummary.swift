public struct PEXExtractorMetricSpreadSummary: Sendable, Codable, Hashable {
    public let metric: String
    public let unit: String
    public let observedCornerCount: Int
    public let minCornerID: String?
    public let minValue: Double?
    public let maxCornerID: String?
    public let maxValue: Double?
    public let spread: Double
    public let relativeSpread: Double?

    public init(
        metric: String,
        unit: String,
        observedCornerCount: Int,
        minCornerID: String?,
        minValue: Double?,
        maxCornerID: String?,
        maxValue: Double?,
        spread: Double,
        relativeSpread: Double?
    ) {
        self.metric = metric
        self.unit = unit
        self.observedCornerCount = observedCornerCount
        self.minCornerID = minCornerID
        self.minValue = minValue
        self.maxCornerID = maxCornerID
        self.maxValue = maxValue
        self.spread = spread
        self.relativeSpread = relativeSpread
    }

    public static func from(
        metric: String,
        unit: String,
        values: [(cornerID: String, value: Double?)]
    ) -> PEXExtractorMetricSpreadSummary {
        let finiteValues = values.compactMap { entry -> (cornerID: String, value: Double)? in
            guard let value = entry.value, value.isFinite else { return nil }
            return (entry.cornerID, value)
        }

        guard !finiteValues.isEmpty else {
            return PEXExtractorMetricSpreadSummary(
                metric: metric,
                unit: unit,
                observedCornerCount: 0,
                minCornerID: nil,
                minValue: nil,
                maxCornerID: nil,
                maxValue: nil,
                spread: 0,
                relativeSpread: nil
            )
        }

        var minEntry = finiteValues[0]
        var maxEntry = finiteValues[0]
        for entry in finiteValues.dropFirst() {
            if entry.value < minEntry.value {
                minEntry = entry
            }
            if entry.value > maxEntry.value {
                maxEntry = entry
            }
        }
        let minValue = minEntry.value
        let maxValue = maxEntry.value
        let spread = maxValue - minValue

        return PEXExtractorMetricSpreadSummary(
            metric: metric,
            unit: unit,
            observedCornerCount: finiteValues.count,
            minCornerID: minEntry.cornerID,
            minValue: minEntry.value,
            maxCornerID: maxEntry.cornerID,
            maxValue: maxEntry.value,
            spread: spread,
            relativeSpread: minValue == 0 ? nil : spread / abs(minValue)
        )
    }
}
