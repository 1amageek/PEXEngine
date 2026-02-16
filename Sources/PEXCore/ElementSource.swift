import Foundation

public enum ElementSource: String, Sendable, Codable, Hashable, CustomStringConvertible {
    case extracted
    case calculated
    case userDefined

    public var description: String { rawValue }
}
