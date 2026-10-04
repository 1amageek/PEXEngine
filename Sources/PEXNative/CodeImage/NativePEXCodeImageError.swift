public enum NativePEXCodeImageError: Error, Sendable, Equatable {
    case imageUnavailable
    case invalidMachO
    case architectureMismatch
    case uuidMismatch
    case byteLimitExceeded
    case changedDuringExecution
    case fileFailure(String)
}
