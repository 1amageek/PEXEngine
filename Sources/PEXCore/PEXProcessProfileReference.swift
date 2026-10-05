import Foundation

public struct PEXProcessProfileReference: Sendable, Codable, Hashable {
    /// Required-view role for the actual profile source bytes used by release qualification.
    public static let qualificationProfileViewRole = "processProfile"

    public let profileID: String?
    public let pdkID: String?
    public let source: String?
    public let requirementID: String?
    public let pdkRoot: String?
    public let primaryDeckPath: String?
    /// Corner-specific extraction decks. A multi-corner run must provide a
    /// distinct existing deck for every requested corner when the backend does
    /// not expose a native corner sweep.
    public let cornerDeckPaths: [String: String]
    /// Immutable standard views required by the selected backend. Keys are
    /// backend-defined semantic roles such as `technologyLEF` or
    /// `libraryLEF:<library-id>`; values are local file paths captured with the
    /// request and included in its stable identity.
    public let requiredViewPaths: [String: String]
    public let metadata: [String: String]

    public init(
        profileID: String? = nil,
        pdkID: String? = nil,
        source: String? = nil,
        requirementID: String? = nil,
        pdkRoot: String? = nil,
        primaryDeckPath: String? = nil,
        cornerDeckPaths: [String: String] = [:],
        requiredViewPaths: [String: String] = [:],
        metadata: [String: String] = [:]
    ) {
        self.profileID = Self.nonEmpty(profileID)
        self.pdkID = Self.nonEmpty(pdkID)
        self.source = Self.nonEmpty(source)
        self.requirementID = Self.nonEmpty(requirementID)
        self.pdkRoot = Self.nonEmpty(pdkRoot)
        self.primaryDeckPath = Self.nonEmpty(primaryDeckPath)
        self.cornerDeckPaths = cornerDeckPaths.reduce(into: [:]) { result, entry in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Self.nonEmpty(entry.value), !key.isEmpty else { return }
            result[key] = value
        }
        self.requiredViewPaths = requiredViewPaths.reduce(into: [:]) { result, entry in
            let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Self.nonEmpty(entry.value), !key.isEmpty else { return }
            result[key] = value
        }
        self.metadata = metadata.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    /// Transforms every declared file input while preserving process identity and discovery context.
    public func mapInputPaths(_ transform: (String) throws -> String) rethrows -> Self {
        try mapInputPathsByRole { _, path in try transform(path) }
    }

    /// Transforms input locations without losing their exact semantic associations.
    public func mapInputPathsByRole(_ transform: (PEXProcessProfileInputRole, String) throws -> String) rethrows -> Self {
        Self(
            profileID: profileID,
            pdkID: pdkID,
            source: source,
            requirementID: requirementID,
            pdkRoot: pdkRoot,
            primaryDeckPath: try primaryDeckPath.map { try transform(.primaryDeck, $0) },
            cornerDeckPaths: try cornerDeckPaths.reduce(into: [:]) { result, entry in
                result[entry.key] = try transform(.cornerDeck(entry.key), entry.value)
            },
            requiredViewPaths: try requiredViewPaths.reduce(into: [:]) { result, entry in
                result[entry.key] = try transform(.requiredView(entry.key), entry.value)
            },
            metadata: metadata
        )
    }

    public func deckPath(for cornerID: PEXCornerID) -> String? {
        cornerDeckPaths[cornerID.value] ?? primaryDeckPath
    }

    private enum CodingKeys: String, CodingKey {
        case profileID
        case pdkID
        case source
        case requirementID
        case pdkRoot
        case primaryDeckPath
        case cornerDeckPaths
        case requiredViewPaths
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            profileID: try container.decodeIfPresent(String.self, forKey: .profileID),
            pdkID: try container.decodeIfPresent(String.self, forKey: .pdkID),
            source: try container.decodeIfPresent(String.self, forKey: .source),
            requirementID: try container.decodeIfPresent(String.self, forKey: .requirementID),
            pdkRoot: try container.decodeIfPresent(String.self, forKey: .pdkRoot),
            primaryDeckPath: try container.decodeIfPresent(String.self, forKey: .primaryDeckPath),
            cornerDeckPaths: try container.decodeIfPresent([String: String].self, forKey: .cornerDeckPaths) ?? [:],
            requiredViewPaths: try container.decodeIfPresent([String: String].self, forKey: .requiredViewPaths) ?? [:],
            metadata: try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
