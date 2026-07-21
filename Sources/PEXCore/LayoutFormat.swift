import Foundation

public enum LayoutFormat: String, Sendable, Codable, Hashable, CustomStringConvertible {
    case gds
    case oas
    case def

    public var description: String { rawValue }
}
