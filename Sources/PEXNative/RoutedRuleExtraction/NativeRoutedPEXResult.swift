import PEXCore

public struct NativeRoutedPEXResult: Sendable, Codable {
    public struct QueryReceipt: Sendable, Codable {
        public let sourceIDs: [String]
        public let context: PEXOpenRCXSourceModel.Context
        public let requestedWidthDatabaseUnits: Int64
        public let requestedDistanceDatabaseUnits: Int64?
        public let evaluatedDistanceDatabaseUnits: Int64?
        public let selectedWidthMicrons: Double
        public let tableSourceRange: PEXOpenRCXSourceModel.SourceRange
        public let sampleSourceRanges: [PEXOpenRCXSourceModel.SourceRange]
        public let effectiveLengthDatabaseUnits: Int64
        public let couplingFarads: Double
        public let fringeFarads: Double
    }
    public struct ViaLandingReceipt: Sendable, Codable {
        public let sourceID: String
        public let selectedLayerName: String
        public let selectedRect: NativeRoutedPEXInput.Rect
        public let sourceFacts: [NativeRoutedPEXInput.SourceFact]
        public let groundCapacitanceFarads: Double
    }
    public let ir: ParasiticIR
    public let selection: PEXOpenRCXSourceModel.Selection
    public let sourceFacts: [NativeRoutedPEXInput.SourceFact]
    public let queryReceipts: [QueryReceipt]
    public let viaLandingReceipts: [ViaLandingReceipt]
    public let workVisitsConsumed: Int
    public let unionSheetEvidence: NativeUnionSheetPEXEvidence?

    init(ir: ParasiticIR, selection: PEXOpenRCXSourceModel.Selection,
         sourceFacts: [NativeRoutedPEXInput.SourceFact], queryReceipts: [QueryReceipt],
         viaLandingReceipts: [ViaLandingReceipt], workVisitsConsumed: Int,
         unionSheetEvidence: NativeUnionSheetPEXEvidence? = nil) {
        self.ir = ir; self.selection = selection; self.sourceFacts = sourceFacts
        self.queryReceipts = queryReceipts; self.viaLandingReceipts = viaLandingReceipts
        self.workVisitsConsumed = workVisitsConsumed; self.unionSheetEvidence = unionSheetEvidence
    }
}
