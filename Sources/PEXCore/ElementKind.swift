import Foundation

public enum ElementKind: String, Sendable, Codable, Hashable, CustomStringConvertible {
    case resistor
    case capacitor
    case coupling

    public var description: String { rawValue }
}
