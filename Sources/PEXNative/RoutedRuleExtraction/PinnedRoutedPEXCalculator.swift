import PEXCore

@available(*, deprecated, message: "Use UnionSheetRoutedPEXCalculator with exact source ground calibration and explicit mesh span; this calculator is retained for legacy/source-law comparison.")
public struct PinnedRoutedPEXCalculator: NativeRoutedPEXCalculating {
    public init() {}
    public func calculate(input: NativeRoutedPEXInput, model: PEXOpenRCXSourceModel, cornerID: PEXCornerID,
                          limits: NativeRoutedPEXLimits, isCancelled: () -> Bool = { Task.isCancelled })
        throws(NativeRoutedPEXError) -> NativeRoutedPEXResult {
        var calculation = try NativeRoutedPEXCalculation(input: input, model: model, limits: limits, isCancelled: isCancelled)
        try calculation.capacitance(isCancelled)
        return try calculation.graph(cornerID: cornerID, isCancelled: isCancelled)
    }
}
