import Foundation

public struct PEXRunID: Sendable, Codable, Hashable, CustomStringConvertible {
    public let value: UUID
    public init() { self.value = UUID() }
    public init(_ value: UUID) { self.value = value }
    public var description: String { value.uuidString }
}
