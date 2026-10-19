import SignoffToolSupport

/// The caller retains cleanup authority when the owned bounded retry cannot finish.
public struct PEXProcessCleanupFailure: Error, Sendable {
    public let processFailure: TimedProcessFailure
    public let retryFailure: String
}
