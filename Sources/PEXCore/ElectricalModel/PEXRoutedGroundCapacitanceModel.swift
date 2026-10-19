import CircuiteFoundation

/// Original LEF calibration values; serialization alone does not establish source authority.
public struct PEXRoutedGroundCapacitanceModel: Sendable, Codable, Hashable {
    public enum Algorithm: String, Sendable, Codable, Hashable {
        case lefAreaBoundaryV1 = "native-lef-area-boundary-v1"
    }

    public struct Layer: Sendable, Codable, Hashable {
        public let name: String
        public let areaPicofaradsPerSquareMicron: Double
        public let edgePicofaradsPerMicron: Double
        public let thicknessMicrons: Double?
        public let sourceRanges: [PEXOpenRCXSourceModel.SourceRange]

        public init(name: String, areaPicofaradsPerSquareMicron: Double,
                    edgePicofaradsPerMicron: Double, thicknessMicrons: Double?,
                    sourceRanges: [PEXOpenRCXSourceModel.SourceRange]) {
            self.name = name
            self.areaPicofaradsPerSquareMicron = areaPicofaradsPerSquareMicron
            self.edgePicofaradsPerMicron = edgePicofaradsPerMicron
            self.thicknessMicrons = thicknessMicrons
            self.sourceRanges = sourceRanges
        }
    }

    public let algorithm: Algorithm
    public let selection: PEXOpenRCXSourceModel.Selection
    public let cornerID: PEXCornerID
    public let capacitanceUnitPicofarads: Double
    public let unitSourceRanges: [PEXOpenRCXSourceModel.SourceRange]
    public let layers: [Layer]

    public init(algorithm: Algorithm = .lefAreaBoundaryV1,
                selection: PEXOpenRCXSourceModel.Selection, cornerID: PEXCornerID,
                capacitanceUnitPicofarads: Double,
                unitSourceRanges: [PEXOpenRCXSourceModel.SourceRange], layers: [Layer]) {
        self.algorithm = algorithm
        self.selection = selection
        self.cornerID = cornerID
        self.capacitanceUnitPicofarads = capacitanceUnitPicofarads
        self.unitSourceRanges = unitSourceRanges
        self.layers = layers
    }
}
