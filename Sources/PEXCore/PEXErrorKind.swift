import Foundation

public enum PEXErrorKind: String, Sendable, Codable, Hashable, CustomStringConvertible {
    case invalidInput
    case technologyResolutionFailed
    case adapterUnavailable
    case backendExecutionFailed
    case cancelled
    case parseFailed
    case irValidationFailed
    case persistenceFailed
    case internalInvariantViolation

    public var description: String { rawValue }
}
