public struct ExtractionRules: Sendable, Codable, Hashable {
    public let minCapacitanceF: Double?
    public let minResistanceOhm: Double?
    public let reductionPolicy: ReductionPolicy

    public enum ReductionPolicy: String, Sendable, Codable, Hashable {
        case none
        case piModel = "pi_model"
        case starModel = "star_model"
    }

    public static let `default` = ExtractionRules(
        minCapacitanceF: nil,
        minResistanceOhm: nil,
        reductionPolicy: .none
    )

    public init(minCapacitanceF: Double?, minResistanceOhm: Double?, reductionPolicy: ReductionPolicy) {
        self.minCapacitanceF = minCapacitanceF
        self.minResistanceOhm = minResistanceOhm
        self.reductionPolicy = reductionPolicy
    }
}
