public struct TechnologyVia: Sendable, Codable, Hashable {
    public let name: String
    public let topLayer: String
    public let bottomLayer: String

    public init(name: String, topLayer: String, bottomLayer: String) {
        self.name = name
        self.topLayer = topLayer
        self.bottomLayer = bottomLayer
    }

    private enum CodingKeys: String, CodingKey { case name, topLayer, bottomLayer }
    private enum RemovedElectricalKeys: String, CodingKey { case resistance }

    public init(from decoder: any Decoder) throws {
        let removed = try decoder.container(keyedBy: RemovedElectricalKeys.self)
        guard !removed.contains(.resistance) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Aggregate via resistance was removed; provide explicit per-cut SI resistance."))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try values.decode(String.self, forKey: .name),
                  topLayer: try values.decode(String.self, forKey: .topLayer),
                  bottomLayer: try values.decode(String.self, forKey: .bottomLayer))
    }
}
