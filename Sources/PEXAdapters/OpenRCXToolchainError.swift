import Foundation

public enum OpenRCXToolchainError: Error, LocalizedError, Sendable, Hashable {
    case executableUnavailable(String?)
    case extractionRulesUnavailable(String?)
    case requiredViewUnavailable(String)
    case libraryViewsUnavailable

    public var errorDescription: String? {
        switch self {
        case .executableUnavailable(let path):
            "OpenROAD executable is unavailable or not executable: \(path ?? "<unspecified>")"
        case .extractionRulesUnavailable(let path):
            "OpenRCX extraction rules are unavailable: \(path ?? "<unspecified>")"
        case .requiredViewUnavailable(let role):
            "OpenRCX required view is unavailable for role '\(role)'."
        case .libraryViewsUnavailable:
            "OpenRCX requires at least one profile-declared library LEF view."
        }
    }
}
