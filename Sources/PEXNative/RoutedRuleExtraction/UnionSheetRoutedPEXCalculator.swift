import PEXCore

/// Native union-sheet RC composition, distinct from the legacy source-bbox model.
public struct UnionSheetRoutedPEXCalculator: NativeRoutedPEXCalculating {
    public init() {}

    public func calculate(input: NativeRoutedPEXInput, model: PEXOpenRCXSourceModel,
                          cornerID: PEXCornerID, limits: NativeRoutedPEXLimits,
                          isCancelled: () -> Bool) throws(NativeRoutedPEXError) -> NativeRoutedPEXResult {
        throw .unsupportedNumericalLaw(reason: "Union-sheet RC requires exact ground calibration and an explicit mesh span")
    }

    public func calculate(input: NativeRoutedPEXInput, model: PEXOpenRCXSourceModel,
                          groundCapacitanceModel: PEXRoutedGroundCapacitanceModel,
                          maximumCellSpanDatabaseUnits: Int32, cornerID: PEXCornerID,
                          limits: NativeRoutedPEXLimits, isCancelled: @Sendable () -> Bool)
        throws(NativeRoutedPEXError) -> NativeRoutedPEXResult {
        var calculation = try UnionSheetRoutedPEXCalculation(input: input, model: model,
            groundModel: groundCapacitanceModel, span: maximumCellSpanDatabaseUnits, limits: limits)
        return try calculation.run(cornerID: cornerID, isCancelled: isCancelled)
    }
}
