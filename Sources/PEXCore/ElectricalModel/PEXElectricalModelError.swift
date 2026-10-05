public enum PEXElectricalModelError: Error, Sendable, Equatable {
    case invalidIdentity(field: String)
    case invalidNumber(field: String)
    case invalidRange(field: String)
    case invalidTopology(field: String)
    case duplicate(field: String)
    case missing(field: String)
    case cornerMismatch(field: String)
    case outOfRange(field: String)
    case unsupportedLawScope(field: String)
}
