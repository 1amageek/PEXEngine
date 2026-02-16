import Foundation

public struct PEXCornerID: Sendable, Codable, Hashable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(stringLiteral value: String) {
        self.value = value
    }

    public var description: String { value }
}
