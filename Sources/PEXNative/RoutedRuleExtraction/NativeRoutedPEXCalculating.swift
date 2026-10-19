import PEXCore

public protocol NativeRoutedPEXCalculating: Sendable {
    func calculate(input: NativeRoutedPEXInput, model: PEXOpenRCXSourceModel,
                   groundCapacitanceModel: PEXRoutedGroundCapacitanceModel,
                   maximumCellSpanDatabaseUnits: Int32, cornerID: PEXCornerID,
                   limits: NativeRoutedPEXLimits, isCancelled: @Sendable () -> Bool)
        throws(NativeRoutedPEXError) -> NativeRoutedPEXResult

    func calculate(input: NativeRoutedPEXInput, model: PEXOpenRCXSourceModel, cornerID: PEXCornerID,
                   limits: NativeRoutedPEXLimits, isCancelled: () -> Bool)
        throws(NativeRoutedPEXError) -> NativeRoutedPEXResult
}

extension NativeRoutedPEXCalculating {
    // FIXME(INCOMPLETE_IMPLEMENTATION): Legacy numerical conformers lack union-sheet RC.
    // Schema-3 native routed execution requires this protocol requirement and must
    // refuse until union R, source area/boundary C and all coupling accounting are implemented.
    public func calculate(input: NativeRoutedPEXInput, model: PEXOpenRCXSourceModel,
                          groundCapacitanceModel: PEXRoutedGroundCapacitanceModel,
                          maximumCellSpanDatabaseUnits: Int32, cornerID: PEXCornerID,
                          limits: NativeRoutedPEXLimits, isCancelled: @Sendable () -> Bool)
        throws(NativeRoutedPEXError) -> NativeRoutedPEXResult {
        throw .unsupportedNumericalLaw(reason: "This calculator does not implement union-sheet routed RC")
    }
}
