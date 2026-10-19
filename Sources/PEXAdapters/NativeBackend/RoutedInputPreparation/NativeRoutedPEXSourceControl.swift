import LogicKernelCore

/// Invocation-local synchronous control; the callback never outlives preparation.
struct NativeRoutedPEXSourceControl: LogicRunControlling {
    let isCancelled: @Sendable () -> Bool
    func checkpoint() throws(LogicKernelError) {
        guard !isCancelled(), !Task.isCancelled else { throw .cancelled }
    }
}
