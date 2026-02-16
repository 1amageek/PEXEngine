import Foundation

public enum PEXRunStatus: String, Sendable, Codable, Hashable, CustomStringConvertible {
    case success
    case partialSuccess
    case failed

    public var description: String { rawValue }
}
