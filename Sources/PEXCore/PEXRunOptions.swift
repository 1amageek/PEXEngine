public struct PEXRunOptions: Sendable, Codable, Hashable {
    public let extractMode: PEXExtractMode
    public let includeCouplingCaps: Bool
    public let minCapacitanceF: Double?
    public let minResistanceOhm: Double?
    public let maxParallelJobs: Int
    public let emitRawArtifacts: Bool
    public let emitIRJSON: Bool
    public let strictValidation: Bool
    public let sourceConnectivityPolicy: PEXSourceConnectivityPolicy

    public static let `default` = PEXRunOptions(
        extractMode: .rc,
        includeCouplingCaps: true,
        minCapacitanceF: nil,
        minResistanceOhm: nil,
        maxParallelJobs: 2,
        emitRawArtifacts: true,
        emitIRJSON: true,
        strictValidation: true,
        sourceConnectivityPolicy: .warn
    )

    public init(
        extractMode: PEXExtractMode,
        includeCouplingCaps: Bool,
        minCapacitanceF: Double?,
        minResistanceOhm: Double?,
        maxParallelJobs: Int,
        emitRawArtifacts: Bool,
        emitIRJSON: Bool,
        strictValidation: Bool,
        sourceConnectivityPolicy: PEXSourceConnectivityPolicy = .warn
    ) {
        self.extractMode = extractMode
        self.includeCouplingCaps = includeCouplingCaps
        self.minCapacitanceF = minCapacitanceF
        self.minResistanceOhm = minResistanceOhm
        self.maxParallelJobs = maxParallelJobs
        self.emitRawArtifacts = emitRawArtifacts
        self.emitIRJSON = emitIRJSON
        self.strictValidation = strictValidation
        self.sourceConnectivityPolicy = sourceConnectivityPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case extractMode
        case includeCouplingCaps
        case minCapacitanceF
        case minResistanceOhm
        case maxParallelJobs
        case emitRawArtifacts
        case emitIRJSON
        case strictValidation
        case sourceConnectivityPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            extractMode: try container.decodeIfPresent(PEXExtractMode.self, forKey: .extractMode) ?? .rc,
            includeCouplingCaps: try container.decodeIfPresent(Bool.self, forKey: .includeCouplingCaps) ?? true,
            minCapacitanceF: try container.decodeIfPresent(Double.self, forKey: .minCapacitanceF),
            minResistanceOhm: try container.decodeIfPresent(Double.self, forKey: .minResistanceOhm),
            maxParallelJobs: try container.decodeIfPresent(Int.self, forKey: .maxParallelJobs) ?? 2,
            emitRawArtifacts: try container.decodeIfPresent(Bool.self, forKey: .emitRawArtifacts) ?? true,
            emitIRJSON: try container.decodeIfPresent(Bool.self, forKey: .emitIRJSON) ?? true,
            strictValidation: try container.decodeIfPresent(Bool.self, forKey: .strictValidation) ?? true,
            sourceConnectivityPolicy: try container.decodeIfPresent(
                PEXSourceConnectivityPolicy.self,
                forKey: .sourceConnectivityPolicy
            ) ?? .disabled
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(extractMode, forKey: .extractMode)
        try container.encode(includeCouplingCaps, forKey: .includeCouplingCaps)
        try container.encodeIfPresent(minCapacitanceF, forKey: .minCapacitanceF)
        try container.encodeIfPresent(minResistanceOhm, forKey: .minResistanceOhm)
        try container.encode(maxParallelJobs, forKey: .maxParallelJobs)
        try container.encode(emitRawArtifacts, forKey: .emitRawArtifacts)
        try container.encode(emitIRJSON, forKey: .emitIRJSON)
        try container.encode(strictValidation, forKey: .strictValidation)
        try container.encode(sourceConnectivityPolicy, forKey: .sourceConnectivityPolicy)
    }
}
