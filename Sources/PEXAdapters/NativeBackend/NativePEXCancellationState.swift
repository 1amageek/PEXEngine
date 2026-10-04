import Synchronization

/// One invocation owns this state; its calculation and monitor share only this lock.
final class NativePEXCancellationState: Sendable {
    private struct State {
        var stage = "identity"
        var cancelled = false
        var monitorFailure: NativePEXBackendError?
    }
    private let storage = Mutex(State())
    var isCancelled: Bool { storage.withLock { $0.cancelled } }
    var stage: String { storage.withLock { $0.stage } }
    var monitorFailure: NativePEXBackendError? { storage.withLock { $0.monitorFailure } }
    func enter(_ stage: String) { storage.withLock { $0.stage = stage } }
    func cancel(_ failure: NativePEXBackendError = .cancelled) {
        storage.withLock { $0.cancelled = true; $0.monitorFailure = failure }
    }
}
