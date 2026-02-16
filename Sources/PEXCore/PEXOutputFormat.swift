import Foundation

public enum PEXOutputFormat: String, Sendable, Codable, Hashable, CustomStringConvertible {
    case spef
    case dspf
    case spice
    case custom

    public var description: String { rawValue }
}
