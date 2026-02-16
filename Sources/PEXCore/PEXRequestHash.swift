import Foundation
import CryptoKit

public struct PEXRequestHash: Sendable, Codable, Hashable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var description: String { value }

    public static func compute(from data: Data) -> PEXRequestHash {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return PEXRequestHash(hex)
    }
}
