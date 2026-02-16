public struct ParasiticUnits: Sendable, Codable, Hashable {
    public let resistance: ResistanceUnit
    public let capacitance: CapacitanceUnit
    public let coordinate: CoordinateUnit

    public enum ResistanceUnit: String, Sendable, Codable, Hashable {
        case ohm
        case kiloOhm = "kohm"
    }

    public enum CapacitanceUnit: String, Sendable, Codable, Hashable {
        case farad = "F"
        case picoFarad = "pF"
        case femtoFarad = "fF"
    }

    public enum CoordinateUnit: String, Sendable, Codable, Hashable {
        case micrometer = "um"
        case nanometer = "nm"
    }

    public static let canonical = ParasiticUnits(
        resistance: .ohm,
        capacitance: .farad,
        coordinate: .micrometer
    )

    public init(resistance: ResistanceUnit, capacitance: CapacitanceUnit, coordinate: CoordinateUnit) {
        self.resistance = resistance
        self.capacitance = capacitance
        self.coordinate = coordinate
    }
}
