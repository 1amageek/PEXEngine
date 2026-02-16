public struct ParasiticIR: Sendable, Codable, Hashable {
    public static let currentVersion = "1.0"

    public let version: String
    public let cornerID: PEXCornerID
    public let units: ParasiticUnits
    public let nets: [ParasiticNet]
    public let elements: [ParasiticElement]
    public let metadata: [String: String]

    public init(version: String, cornerID: PEXCornerID, units: ParasiticUnits, nets: [ParasiticNet], elements: [ParasiticElement], metadata: [String: String]) {
        self.version = version
        self.cornerID = cornerID
        self.units = units
        self.nets = nets
        self.elements = elements
        self.metadata = metadata
    }
}
