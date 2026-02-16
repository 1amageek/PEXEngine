import Foundation

public enum PEXExtractMode: String, Sendable, Codable, Hashable, CustomStringConvertible {
    case rc
    case cOnly = "c_only"
    case rOnly = "r_only"

    public var description: String { rawValue }
}
