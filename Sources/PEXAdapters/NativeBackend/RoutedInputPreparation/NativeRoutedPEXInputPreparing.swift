import PEXCore

public protocol NativeRoutedPEXInputPreparing: Sendable {
    func prepare(context: PEXExecutionContext, requiredCornerIDs: [PEXCornerID], isCancelled: @Sendable () -> Bool)
        throws(NativeRoutedPEXPreparationError) -> PreparedNativeRoutedPEXInput
}
