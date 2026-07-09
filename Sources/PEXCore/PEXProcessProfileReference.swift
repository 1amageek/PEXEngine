import Foundation

public struct PEXProcessProfileReference: Sendable, Codable, Hashable {
    public let profileID: String?
    public let pdkID: String?
    public let source: String?
    public let requirementID: String?
    public let pdkRoot: String?
    public let primaryDeckPath: String?
    public let metadata: [String: String]

    public init(
        profileID: String? = nil,
        pdkID: String? = nil,
        source: String? = nil,
        requirementID: String? = nil,
        pdkRoot: String? = nil,
        primaryDeckPath: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.profileID = Self.nonEmpty(profileID)
        self.pdkID = Self.nonEmpty(pdkID)
        self.source = Self.nonEmpty(source)
        self.requirementID = Self.nonEmpty(requirementID)
        self.pdkRoot = Self.nonEmpty(pdkRoot)
        self.primaryDeckPath = Self.nonEmpty(primaryDeckPath)
        self.metadata = metadata.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
