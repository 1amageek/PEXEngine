public struct TechnologyLayer: Sendable, Codable, Hashable {
    public let name: String
    public let order: Int
    public let material: String?

    public init(name: String, order: Int, material: String? = nil) {
        self.name = name
        self.order = order
        self.material = material
    }

    private enum CodingKeys: String, CodingKey { case name, order, material }
    private enum RemovedElectricalKeys: String, CodingKey { case thickness, resistivity }

    public init(from decoder: any Decoder) throws {
        let removed = try decoder.container(keyedBy: RemovedElectricalKeys.self)
        guard !removed.contains(.thickness), !removed.contains(.resistivity) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Layer electrical fields were removed; provide an explicit SI electrical model."))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try values.decode(String.self, forKey: .name),
                  order: try values.decode(Int.self, forKey: .order),
                  material: try values.decodeIfPresent(String.self, forKey: .material))
    }
}
