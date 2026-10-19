/// Captured physical facts, independent of extraction completion and source identity.
public struct PEXPhysicalTopology: Sendable, Codable, Hashable {
    public let openNetCount: Int
    public let shortComponentCount: Int
    public let uncontactedTerminalCount: Int
    public var isSatisfied: Bool { openNetCount == 0 && shortComponentCount == 0 && uncontactedTerminalCount == 0 }

    public init(openNetCount: Int, shortComponentCount: Int, uncontactedTerminalCount: Int) throws(PEXBackendResultError) {
        guard openNetCount >= 0, shortComponentCount >= 0, uncontactedTerminalCount >= 0 else { throw .invalidPhysicalTopology }
        self.openNetCount = openNetCount; self.shortComponentCount = shortComponentCount
        self.uncontactedTerminalCount = uncontactedTerminalCount
    }
    private enum CodingKeys: String, CodingKey { case openNetCount, shortComponentCount, uncontactedTerminalCount }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(openNetCount: c.decode(Int.self, forKey: .openNetCount),
            shortComponentCount: c.decode(Int.self, forKey: .shortComponentCount),
            uncontactedTerminalCount: c.decode(Int.self, forKey: .uncontactedTerminalCount))
    }
}
