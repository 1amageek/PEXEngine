import Foundation

public struct PEXError: Error, Sendable, CustomStringConvertible {
    public let kind: PEXErrorKind
    public let stage: PEXStage
    public let runID: PEXRunID?
    public let cornerID: PEXCornerID?
    public let backendID: String?
    public let message: String
    public let underlyingDescription: String?
    public let diagnosticFileURL: URL?

    public var description: String {
        var parts: [String] = ["[\(stage.rawValue)]"]
        if let cornerID { parts.append("corner=\(cornerID)") }
        if let backendID { parts.append("backend=\(backendID)") }
        parts.append(message)
        return parts.joined(separator: " ")
    }

    public init(
        kind: PEXErrorKind,
        stage: PEXStage,
        runID: PEXRunID? = nil,
        cornerID: PEXCornerID? = nil,
        backendID: String? = nil,
        message: String,
        underlyingDescription: String? = nil,
        diagnosticFileURL: URL? = nil
    ) {
        self.kind = kind
        self.stage = stage
        self.runID = runID
        self.cornerID = cornerID
        self.backendID = backendID
        self.message = message
        self.underlyingDescription = underlyingDescription
        self.diagnosticFileURL = diagnosticFileURL
    }

    // Factory methods
    public static func invalidInput(_ message: String) -> PEXError {
        PEXError(kind: .invalidInput, stage: .inputValidation, message: message)
    }

    public static func technologyResolutionFailed(_ message: String, underlying: (any Error)? = nil) -> PEXError {
        PEXError(kind: .technologyResolutionFailed, stage: .technologyResolution, message: message, underlyingDescription: underlying.map { String(describing: $0) })
    }

    public static func adapterUnavailable(backendID: String) -> PEXError {
        PEXError(kind: .adapterUnavailable, stage: .adapterPreparation, backendID: backendID, message: "No adapter registered for backend '\(backendID)'")
    }

    public static func backendExecutionFailed(backendID: String, cornerID: PEXCornerID, message: String, underlying: (any Error)? = nil) -> PEXError {
        PEXError(kind: .backendExecutionFailed, stage: .backendExecution, cornerID: cornerID, backendID: backendID, message: message, underlyingDescription: underlying.map { String(describing: $0) })
    }

    public static func parseFailed(cornerID: PEXCornerID, message: String, underlying: (any Error)? = nil) -> PEXError {
        PEXError(kind: .parseFailed, stage: .parsing, cornerID: cornerID, message: message, underlyingDescription: underlying.map { String(describing: $0) })
    }

    public static func irValidationFailed(cornerID: PEXCornerID, errors: [ParasiticIRValidationError]) -> PEXError {
        let descriptions = errors.map { String(describing: $0) }.joined(separator: "; ")
        return PEXError(kind: .irValidationFailed, stage: .irValidation, cornerID: cornerID, message: "IR validation failed: \(descriptions)")
    }

    public static func persistenceFailed(_ message: String, underlying: (any Error)? = nil) -> PEXError {
        PEXError(kind: .persistenceFailed, stage: .persistence, message: message, underlyingDescription: underlying.map { String(describing: $0) })
    }

    public static func internalInvariantViolation(_ message: String) -> PEXError {
        PEXError(kind: .internalInvariantViolation, stage: .reporting, message: message)
    }
}
