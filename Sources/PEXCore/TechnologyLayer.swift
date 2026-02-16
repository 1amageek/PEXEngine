public struct TechnologyLayer: Sendable, Codable, Hashable {
    public let name: String
    public let order: Int
    public let thickness: Double?
    public let material: String?
    public let resistivity: Double?

    public init(name: String, order: Int, thickness: Double?, material: String?, resistivity: Double?) {
        self.name = name
        self.order = order
        self.thickness = thickness
        self.material = material
        self.resistivity = resistivity
    }
}
