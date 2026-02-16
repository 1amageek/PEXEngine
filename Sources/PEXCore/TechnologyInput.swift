import Foundation

public enum TechnologyInput: Sendable, Codable, Hashable {
    case jsonFile(URL)
    case tomlFile(URL)
    case directory(URL)
    case inline(TechnologyIR)

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case type
        case url
        case value
    }

    private enum InputType: String, Codable {
        case jsonFile
        case tomlFile
        case directory
        case inline
    }

    // MARK: - Decodable

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(InputType.self, forKey: .type)
        switch type {
        case .jsonFile:
            let url = try container.decode(URL.self, forKey: .url)
            self = .jsonFile(url)
        case .tomlFile:
            let url = try container.decode(URL.self, forKey: .url)
            self = .tomlFile(url)
        case .directory:
            let url = try container.decode(URL.self, forKey: .url)
            self = .directory(url)
        case .inline:
            let value = try container.decode(TechnologyIR.self, forKey: .value)
            self = .inline(value)
        }
    }

    // MARK: - Encodable

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .jsonFile(let url):
            try container.encode(InputType.jsonFile, forKey: .type)
            try container.encode(url, forKey: .url)
        case .tomlFile(let url):
            try container.encode(InputType.tomlFile, forKey: .type)
            try container.encode(url, forKey: .url)
        case .directory(let url):
            try container.encode(InputType.directory, forKey: .type)
            try container.encode(url, forKey: .url)
        case .inline(let value):
            try container.encode(InputType.inline, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}
