/// Explicit SI parameters for the single-plane coplanar and ground-fringe law.
/// Source-derived parameters identify an approximation, not foundry qualification.
public struct PEXCoplanarScreening: Sendable, Codable, Hashable {
    public let offsetMeters: Double
    public let interactionHaloMeters: Double
    public let groundFringeInverseMeters: Double

    public init(offsetMeters: Double, interactionHaloMeters: Double, groundFringeInverseMeters: Double) {
        self.offsetMeters = offsetMeters
        self.interactionHaloMeters = interactionHaloMeters
        self.groundFringeInverseMeters = groundFringeInverseMeters
    }

    func validate() throws(PEXElectricalModelError) {
        try ElectricalModelAdmission.number(offsetMeters, field: "coplanarScreening.offsetMeters")
        try ElectricalModelAdmission.number(interactionHaloMeters, field: "coplanarScreening.interactionHaloMeters", positive: true)
        try ElectricalModelAdmission.number(groundFringeInverseMeters, field: "coplanarScreening.groundFringeInverseMeters")
    }
}
