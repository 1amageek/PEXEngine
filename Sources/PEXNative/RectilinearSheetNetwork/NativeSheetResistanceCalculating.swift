public protocol NativeSheetResistanceCalculating: Sendable {
    func calculate(input: NativeSheetResistanceInput, maximumCellSpanDatabaseUnits: Int32,
                   limits: NativeSheetResistanceLimits, isCancelled: @Sendable () -> Bool)
        throws(NativeSheetResistanceError) -> NativeSheetResistanceResult
}
