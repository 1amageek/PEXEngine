import Foundation

public struct NodeName: Sendable, Codable, Hashable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var description: String { value }
}
