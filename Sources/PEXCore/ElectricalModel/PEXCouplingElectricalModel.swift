public struct PEXCouplingElectricalModel: Sendable, Codable, Hashable {
    public let firstLayerName: String
    public let secondLayerName: String
    public let areaFaradsPerSquareMeter: Double
    public let sidewallFarads: Double
    public let gapRange: PEXDimensionRangeMeters

    public init(firstLayerName: String, secondLayerName: String, areaFaradsPerSquareMeter: Double,
                sidewallFarads: Double, gapRange: PEXDimensionRangeMeters) {
        self.firstLayerName = firstLayerName
        self.secondLayerName = secondLayerName
        self.areaFaradsPerSquareMeter = areaFaradsPerSquareMeter
        self.sidewallFarads = sidewallFarads
        self.gapRange = gapRange
    }

    func validate() throws(PEXElectricalModelError) {
        try ElectricalModelAdmission.identity(firstLayerName, field: "coupling.firstLayerName")
        try ElectricalModelAdmission.identity(secondLayerName, field: "coupling.secondLayerName")
        try ElectricalModelAdmission.number(areaFaradsPerSquareMeter, field: "coupling.areaFaradsPerSquareMeter")
        try ElectricalModelAdmission.number(sidewallFarads, field: "coupling.sidewallFarads")
        try gapRange.validate(field: "coupling.gapRange")
    }
}
