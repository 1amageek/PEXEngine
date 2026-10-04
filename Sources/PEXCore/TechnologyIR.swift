public struct TechnologyIR: Sendable, Codable, Hashable {
    public let processName: String
    public let stack: [TechnologyLayer]
    public let logicalToPhysicalLayerMap: [String: String]
    public let vias: [TechnologyVia]
    public let defaultExtractionRules: ExtractionRules
    public let backendHints: [String: [String: String]]
    public let electricalModels: [PEXElectricalModel]?

    public init(processName: String, stack: [TechnologyLayer], logicalToPhysicalLayerMap: [String: String], vias: [TechnologyVia], defaultExtractionRules: ExtractionRules, backendHints: [String: [String: String]], electricalModels: [PEXElectricalModel]? = nil) {
        self.processName = processName
        self.stack = stack
        self.logicalToPhysicalLayerMap = logicalToPhysicalLayerMap
        self.vias = vias
        self.defaultExtractionRules = defaultExtractionRules
        self.backendHints = backendHints
        self.electricalModels = electricalModels
    }
}
