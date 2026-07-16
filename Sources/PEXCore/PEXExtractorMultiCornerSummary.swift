public struct PEXExtractorMultiCornerSummary: Sendable, Codable, Hashable {
    public let comparisonStatus: PEXExtractorMultiCornerComparisonStatus
    public let comparisonBasis: PEXExtractorMultiCornerComparisonBasis
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
        comparisonBasis: PEXExtractorMultiCornerComparisonBasis,
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
        self.comparisonBasis = comparisonBasis
        self.cornerCount = cornerCount
        self.successfulCornerCount = successfulCornerCount
        self.failedCornerCount = failedCornerCount
        self.comparableCornerCount = comparableCornerCount
        self.failedCornerIDs = Array(Set(failedCornerIDs.filter { !$0.isEmpty })).sorted()
        self.totalCapacitance = totalCapacitance
        self.totalResistance = totalResistance
        self.notes = notes.filter { !$0.isEmpty }
    }

    public init(
        cornerResults: [PEXExtractorRunResult.CornerSummary],
        comparisonBasis: PEXExtractorMultiCornerComparisonBasis,
        additionalNotes: [String] = []
    ) {
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

        var notes: [String] = additionalNotes
        if !failedCornerIDs.isEmpty {
            notes.append("One or more corners failed before comparable PEX evidence was produced.")
        }
        if cornerResults.count > 1 && comparableCornerIDs.count < 2 {
            notes.append("Fewer than two successful corners expose comparable parasitic totals.")
        }

        self.init(
            comparisonStatus: comparisonStatus,
            comparisonBasis: comparisonBasis,
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

    private enum CodingKeys: String, CodingKey {
        case comparisonStatus
        case comparisonBasis
        case cornerCount
        case successfulCornerCount
        case failedCornerCount
        case comparableCornerCount
        case failedCornerIDs
        case totalCapacitance
        case totalResistance
        case notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            comparisonStatus: try container.decode(
                PEXExtractorMultiCornerComparisonStatus.self,
                forKey: .comparisonStatus
            ),
            comparisonBasis: try container.decode(
                PEXExtractorMultiCornerComparisonBasis.self,
                forKey: .comparisonBasis
            ),
            cornerCount: try container.decode(Int.self, forKey: .cornerCount),
            successfulCornerCount: try container.decode(Int.self, forKey: .successfulCornerCount),
            failedCornerCount: try container.decode(Int.self, forKey: .failedCornerCount),
            comparableCornerCount: try container.decode(Int.self, forKey: .comparableCornerCount),
            failedCornerIDs: try container.decode([String].self, forKey: .failedCornerIDs),
            totalCapacitance: try container.decode(
                PEXExtractorMetricSpreadSummary.self,
                forKey: .totalCapacitance
            ),
            totalResistance: try container.decode(
                PEXExtractorMetricSpreadSummary.self,
                forKey: .totalResistance
            ),
            notes: try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(comparisonStatus, forKey: .comparisonStatus)
        try container.encode(comparisonBasis, forKey: .comparisonBasis)
        try container.encode(cornerCount, forKey: .cornerCount)
        try container.encode(successfulCornerCount, forKey: .successfulCornerCount)
        try container.encode(failedCornerCount, forKey: .failedCornerCount)
        try container.encode(comparableCornerCount, forKey: .comparableCornerCount)
        try container.encode(failedCornerIDs, forKey: .failedCornerIDs)
        try container.encode(totalCapacitance, forKey: .totalCapacitance)
        try container.encode(totalResistance, forKey: .totalResistance)
        try container.encode(notes, forKey: .notes)
    }
}
