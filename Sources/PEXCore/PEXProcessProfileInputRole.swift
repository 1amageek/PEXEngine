import Foundation

/// Exact semantic association of retained process-profile input bytes.
public enum PEXProcessProfileInputRole: Sendable, Codable, Hashable {
    case primaryDeck
    case cornerDeck(String)
    case requiredView(String)

    public var artifactKind: PEXArtifactKind {
        switch self {
        case .primaryDeck, .cornerDeck: .processProfileDeckInput
        case .requiredView: .processProfileViewInput
        }
    }

    func validate() throws {
        switch self {
        case .primaryDeck: break
        case .cornerDeck(let key), .requiredView(let key):
            _ = try PEXArtifactRecordID(rawValue: key)
        }
    }

    private enum Kind: String, Codable { case primaryDeck, cornerDeck, requiredView }
    private enum CodingKeys: String, CodingKey { case kind, identifier }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .primaryDeck:
            guard !container.contains(.identifier) else {
                throw PEXError.invalidInput("A primary-deck role does not have an identifier")
            }
            self = .primaryDeck
        case .cornerDeck: self = .cornerDeck(try container.decode(String.self, forKey: .identifier))
        case .requiredView: self = .requiredView(try container.decode(String.self, forKey: .identifier))
        }
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .primaryDeck: try container.encode(Kind.primaryDeck, forKey: .kind)
        case .cornerDeck(let key):
            try container.encode(Kind.cornerDeck, forKey: .kind)
            try container.encode(key, forKey: .identifier)
        case .requiredView(let key):
            try container.encode(Kind.requiredView, forKey: .kind)
            try container.encode(key, forKey: .identifier)
        }
    }
}
