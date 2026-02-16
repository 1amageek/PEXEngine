public struct TechnologyVia: Sendable, Codable, Hashable {
    public let name: String
    public let topLayer: String
    public let bottomLayer: String
    public let resistance: Double?

    public init(name: String, topLayer: String, bottomLayer: String, resistance: Double?) {
        self.name = name
        self.topLayer = topLayer
        self.bottomLayer = bottomLayer
        self.resistance = resistance
    }
}
