public struct PEXCorner: Sendable, Codable, Hashable {
    public let id: PEXCornerID
    public let name: String
    public let temperature: Double?
    public let voltage: Double?
    public let parameters: [String: String]

    public init(
        id: PEXCornerID,
        name: String,
        temperature: Double? = nil,
        voltage: Double? = nil,
        parameters: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.temperature = temperature
        self.voltage = voltage
        self.parameters = parameters
    }

    public init(id: String) {
        self.id = PEXCornerID(id)
        self.name = id
        self.temperature = nil
        self.voltage = nil
        self.parameters = [:]
    }
}
