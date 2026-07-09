public struct PEXExtractorCornerMetadata: Sendable, Codable, Hashable {
    public let cornerID: PEXCornerID
    public let name: String
    public let temperatureC: Double?
    public let voltageV: Double?
    public let parameters: [String: String]

    public init(
        cornerID: PEXCornerID,
        name: String,
        temperatureC: Double? = nil,
        voltageV: Double? = nil,
        parameters: [String: String] = [:]
    ) {
        self.cornerID = cornerID
        self.name = name
        self.temperatureC = temperatureC
        self.voltageV = voltageV
        self.parameters = parameters.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    public init(corner: PEXCorner) {
        self.init(
            cornerID: corner.id,
            name: corner.name,
            temperatureC: corner.temperature,
            voltageV: corner.voltage,
            parameters: corner.parameters
        )
    }
}
