import PEXCore

public struct RectilinearSheetResistanceCalculator: NativeSheetResistanceCalculating {
    public init() {}

    public func calculate(input: NativeSheetResistanceInput, maximumCellSpanDatabaseUnits: Int32,
                          limits: NativeSheetResistanceLimits, isCancelled: @Sendable () -> Bool)
        throws(NativeSheetResistanceError) -> NativeSheetResistanceResult {
        var accounting: any NativeConductorResourceAccounting = try NativeSheetResistanceBudget(limits)
        return try calculate(input: input, maximumCellSpanDatabaseUnits: maximumCellSpanDatabaseUnits,
                             accounting: &accounting, isCancelled: isCancelled)
    }

    /// The caller's cumulative ledger is returned on success and failure without resetting it.
    func calculate(input: NativeSheetResistanceInput, maximumCellSpanDatabaseUnits: Int32,
                   accounting: inout any NativeConductorResourceAccounting,
                   isCancelled: @Sendable () -> Bool) throws(NativeSheetResistanceError) -> NativeSheetResistanceResult {
        // Work and its callback are destroyed within this synchronous scope, before returning the value-only result.
        let result: Result<NativeSheetResistanceResult, NativeSheetResistanceError> = withoutActuallyEscaping(isCancelled) { callback in
            var work = SheetResistanceWork(accounting: accounting, isCancelled: callback)
            defer { accounting = work.accounting }
            var calculation = SheetResistanceCalculation(input: input, span: maximumCellSpanDatabaseUnits)
            return Result(catching: { () throws(NativeSheetResistanceError) -> NativeSheetResistanceResult in
                try calculation.run(work: &work)
            })
        }
        return try result.get()
    }
}
