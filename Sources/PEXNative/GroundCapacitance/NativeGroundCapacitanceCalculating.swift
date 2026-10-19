import PEXCore

public protocol NativeGroundCapacitanceCalculating: Sendable {
    func calculate(union: NativeConductorUnion, model: PEXRoutedGroundCapacitanceModel,
                   selection: PEXOpenRCXSourceModel.Selection, cornerID: PEXCornerID,
                   limits: NativeGroundCapacitanceLimits, isCancelled: () -> Bool)
        throws(NativeGroundCapacitanceError) -> NativeGroundCapacitanceResult
}
