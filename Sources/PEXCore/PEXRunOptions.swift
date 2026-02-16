public struct PEXRunOptions: Sendable, Codable, Hashable {
    public let extractMode: PEXExtractMode
    public let includeCouplingCaps: Bool
    public let minCapacitanceF: Double?
    public let minResistanceOhm: Double?
    public let maxParallelJobs: Int
    public let emitRawArtifacts: Bool
    public let emitIRJSON: Bool
    public let strictValidation: Bool

    public static let `default` = PEXRunOptions(
        extractMode: .rc,
        includeCouplingCaps: true,
        minCapacitanceF: nil,
        minResistanceOhm: nil,
        maxParallelJobs: 2,
        emitRawArtifacts: true,
        emitIRJSON: true,
        strictValidation: false
    )

    public init(
        extractMode: PEXExtractMode,
        includeCouplingCaps: Bool,
        minCapacitanceF: Double?,
        minResistanceOhm: Double?,
        maxParallelJobs: Int,
        emitRawArtifacts: Bool,
        emitIRJSON: Bool,
        strictValidation: Bool
    ) {
        self.extractMode = extractMode
        self.includeCouplingCaps = includeCouplingCaps
        self.minCapacitanceF = minCapacitanceF
        self.minResistanceOhm = minResistanceOhm
        self.maxParallelJobs = maxParallelJobs
        self.emitRawArtifacts = emitRawArtifacts
        self.emitIRJSON = emitIRJSON
        self.strictValidation = strictValidation
    }
}
