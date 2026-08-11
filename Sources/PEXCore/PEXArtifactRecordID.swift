import Foundation

public struct PEXArtifactRecordID: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public var description: String { rawValue }

    public init(rawValue: String) throws {
        guard !rawValue.isEmpty,
              rawValue.trimmingCharacters(in: .whitespacesAndNewlines) == rawValue,
              !rawValue.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PEXError.invalidInput("PEX artifact record ID must be a non-empty token")
        }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
