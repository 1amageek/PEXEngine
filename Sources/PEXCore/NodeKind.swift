import Foundation

public enum NodeKind: String, Sendable, Codable, Hashable, CustomStringConvertible {
    case pin
    case `internal`
    case substrate
    case ground

    public var description: String { rawValue }
}
