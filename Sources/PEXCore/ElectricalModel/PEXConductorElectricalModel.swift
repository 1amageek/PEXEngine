public struct PEXConductorElectricalModel: Sendable, Codable, Hashable {
    public let layerName: String
    public let bottomHeightMeters: Double
    public let thicknessMeters: Double
    public let resistivityOhmMeters: Double
    public let groundAreaFaradsPerSquareMeter: Double
    public let groundPerimeterFaradsPerMeter: Double
    public let widthRange: PEXDimensionRangeMeters
    public let lengthRange: PEXDimensionRangeMeters

    public init(layerName: String, bottomHeightMeters: Double, thicknessMeters: Double,
                resistivityOhmMeters: Double, groundAreaFaradsPerSquareMeter: Double,
                groundPerimeterFaradsPerMeter: Double, widthRange: PEXDimensionRangeMeters,
                lengthRange: PEXDimensionRangeMeters) {
        self.layerName = layerName
        self.bottomHeightMeters = bottomHeightMeters
        self.thicknessMeters = thicknessMeters
        self.resistivityOhmMeters = resistivityOhmMeters
        self.groundAreaFaradsPerSquareMeter = groundAreaFaradsPerSquareMeter
        self.groundPerimeterFaradsPerMeter = groundPerimeterFaradsPerMeter
        self.widthRange = widthRange
        self.lengthRange = lengthRange
    }

    public func sheetResistanceOhms() throws(PEXElectricalModelError) -> Double {
        try ElectricalModelAdmission.number(thicknessMeters, field: "\(layerName).thicknessMeters", positive: true)
        try ElectricalModelAdmission.number(resistivityOhmMeters, field: "\(layerName).resistivityOhmMeters", positive: true)
        let result = resistivityOhmMeters / thicknessMeters
        try ElectricalModelAdmission.number(result, field: "\(layerName).sheetResistanceOhms", positive: true)
        return result
    }

    func validate() throws(PEXElectricalModelError) {
        try ElectricalModelAdmission.identity(layerName, field: "conductor.layerName")
        _ = try sheetResistanceOhms()
        try ElectricalModelAdmission.number(bottomHeightMeters, field: "\(layerName).bottomHeightMeters")
        let topHeightMeters = bottomHeightMeters + thicknessMeters
        try ElectricalModelAdmission.number(topHeightMeters, field: "\(layerName).topHeightMeters", positive: true)
        guard topHeightMeters > bottomHeightMeters else {
            throw .invalidNumber(field: "\(layerName).topHeightMeters")
        }
        try ElectricalModelAdmission.number(groundAreaFaradsPerSquareMeter, field: "\(layerName).groundAreaFaradsPerSquareMeter")
        try ElectricalModelAdmission.number(groundPerimeterFaradsPerMeter, field: "\(layerName).groundPerimeterFaradsPerMeter")
        try widthRange.validate(field: "\(layerName).widthRange")
        try lengthRange.validate(field: "\(layerName).lengthRange")
    }
}
