public struct PEXExtractorMultiCornerSummary: Sendable, Codable, Hashable {
    public let comparisonStatus: PEXExtractorMultiCornerComparisonStatus
    public let cornerCount: Int
    public let successfulCornerCount: Int
    public let failedCornerCount: Int
    public let comparableCornerCount: Int
    public let failedCornerIDs: [String]
    public let totalCapacitance: PEXExtractorMetricSpreadSummary
    public let totalResistance: PEXExtractorMetricSpreadSummary
    public let notes: [String]

    public var worstCapacitanceCornerID: String? {
        totalCapacitance.maxCornerID
    }

    public var worstResistanceCornerID: String? {
        totalResistance.maxCornerID
    }

    public init(
        comparisonStatus: PEXExtractorMultiCornerComparisonStatus,
        cornerCount: Int,
        successfulCornerCount: Int,
        failedCornerCount: Int,
        comparableCornerCount: Int,
        failedCornerIDs: [String],
        totalCapacitance: PEXExtractorMetricSpreadSummary,
        totalResistance: PEXExtractorMetricSpreadSummary,
        notes: [String] = []
    ) {
        self.comparisonStatus = comparisonStatus
        self.cornerCount = cornerCount
        self.successfulCornerCount = successfulCornerCount
        self.failedCornerCount = failedCornerCount
        self.comparableCornerCount = comparableCornerCount
        self.failedCornerIDs = Array(Set(failedCornerIDs.filter { !$0.isEmpty })).sorted()
        self.totalCapacitance = totalCapacitance
        self.totalResistance = totalResistance
        self.notes = notes.filter { !$0.isEmpty }
    }

    public init(cornerResults: [PEXExtractorRunResult.CornerSummary]) {
        let successfulCorners = cornerResults.filter { $0.status == .success }
        let failedCornerIDs = cornerResults
            .filter { $0.status != .success }
            .map(\.cornerID.value)
        let comparableCornerIDs = Set(successfulCorners.compactMap { corner -> String? in
            let hasCap = corner.totalCapacitanceF?.isFinite == true
            let hasResistance = corner.totalResistanceOhm?.isFinite == true
            return hasCap || hasResistance ? corner.cornerID.value : nil
        })
        let comparisonStatus: PEXExtractorMultiCornerComparisonStatus
        if successfulCorners.isEmpty {
            comparisonStatus = .noSuccessfulCorners
        } else if !failedCornerIDs.isEmpty {
            comparisonStatus = .partialFailure
        } else if comparableCornerIDs.count < 2 {
            comparisonStatus = .singleCorner
        } else {
            comparisonStatus = .comparable
        }

        var notes: [String] = []
        if !failedCornerIDs.isEmpty {
            notes.append("One or more corners failed before comparable PEX evidence was produced.")
        }
        if cornerResults.count > 1 && comparableCornerIDs.count < 2 {
            notes.append("Fewer than two successful corners expose comparable parasitic totals.")
        }

        self.init(
            comparisonStatus: comparisonStatus,
            cornerCount: cornerResults.count,
            successfulCornerCount: successfulCorners.count,
            failedCornerCount: failedCornerIDs.count,
            comparableCornerCount: comparableCornerIDs.count,
            failedCornerIDs: failedCornerIDs,
            totalCapacitance: PEXExtractorMetricSpreadSummary.from(
                metric: "totalCapacitanceF",
                unit: "F",
                values: successfulCorners.map { ($0.cornerID.value, $0.totalCapacitanceF) }
            ),
            totalResistance: PEXExtractorMetricSpreadSummary.from(
                metric: "totalResistanceOhm",
                unit: "ohm",
                values: successfulCorners.map { ($0.cornerID.value, $0.totalResistanceOhm) }
            ),
            notes: notes
        )
    }
}
