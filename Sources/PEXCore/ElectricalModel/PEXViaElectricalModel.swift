public struct PEXViaElectricalModel: Sendable, Codable, Hashable {
    public let viaName: String
    public let cutLayerName: String
    public let bottomLayerName: String
    public let topLayerName: String
    public let resistanceOhmsPerCut: Double
    public let cutWidthRange: PEXDimensionRangeMeters
    public let cutHeightRange: PEXDimensionRangeMeters

    public init(viaName: String, cutLayerName: String, bottomLayerName: String, topLayerName: String,
                resistanceOhmsPerCut: Double, cutWidthRange: PEXDimensionRangeMeters,
                cutHeightRange: PEXDimensionRangeMeters) {
        self.viaName = viaName
        self.cutLayerName = cutLayerName
        self.bottomLayerName = bottomLayerName
        self.topLayerName = topLayerName
        self.resistanceOhmsPerCut = resistanceOhmsPerCut
        self.cutWidthRange = cutWidthRange
        self.cutHeightRange = cutHeightRange
    }

    func validate() throws(PEXElectricalModelError) {
        for (field, value) in [("viaName", viaName), ("cutLayerName", cutLayerName),
                               ("bottomLayerName", bottomLayerName), ("topLayerName", topLayerName)] {
            try ElectricalModelAdmission.identity(value, field: "via.\(field)")
        }
        try ElectricalModelAdmission.number(resistanceOhmsPerCut, field: "\(viaName).resistanceOhmsPerCut", positive: true)
        try cutWidthRange.validate(field: "\(viaName).cutWidthRange")
        try cutHeightRange.validate(field: "\(viaName).cutHeightRange")
    }
}
