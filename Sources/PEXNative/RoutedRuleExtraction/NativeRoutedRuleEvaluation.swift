import PEXCore

/// Numerical source-law result and exact source evidence, without checked authority.
public struct NativeRoutedRuleEvaluation: Sendable {
    public let workVisitsConsumed: Int
    public let context: PEXOpenRCXSourceModel.Context
    public let selectedWidthMicrons: Double
    public let tableSourceRange: PEXOpenRCXSourceModel.SourceRange
    public let sampleSourceRanges: [PEXOpenRCXSourceModel.SourceRange]
    public let evaluatedDistanceDatabaseUnits: Int64?
    public let couplingFaradsPerDatabaseUnit: Double
    public let fringeFaradsPerDatabaseUnit: Double
    public let resistanceOhmsPerDatabaseUnit: Double

    /// Pinned DIAGUNDER consumes the fringe column as the diagonal coupling law.
    public var physicalCouplingFaradsPerDatabaseUnit: Double {
        context.kind == .diagUnder ? fringeFaradsPerDatabaseUnit : couplingFaradsPerDatabaseUnit
    }
}
