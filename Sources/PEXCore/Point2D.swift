import Foundation

public struct Point2D: Sendable, Codable, Hashable, CustomStringConvertible {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var description: String { "(\(x), \(y))" }
}
