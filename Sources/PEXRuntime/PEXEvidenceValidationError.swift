import Foundation

public enum PEXEvidenceValidationError: Error, Sendable, Equatable {
    case reportDecodeFailed(String)
    case corpusMismatch
    case correlationContentMismatch
}

extension PEXEvidenceValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .reportDecodeFailed(reason):
            "PEX corpus report could not be decoded: \(reason)."
        case .corpusMismatch:
            "PEX extractor corpus is invalid or is not canonically encoded."
        case .correlationContentMismatch:
            "PEX extractor correlation is invalid or is not canonically encoded."
        }
    }
}
