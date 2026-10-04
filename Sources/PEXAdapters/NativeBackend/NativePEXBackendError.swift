public enum NativePEXBackendError: Error, Sendable, Equatable {
    case invalidLimits
    case missingConfiguration
    case unsupportedRequest(String)
    case missingCalibration
    case calibrationMismatch
    case evidenceByteLimitExceeded
    case cancelled
    case cancellationCheckFailed(String)
}
