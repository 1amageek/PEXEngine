import PEXCore

/// Portable numerical observations. Decoding these values does not admit source or qualify a model.
public struct NativeUnionSheetPEXEvidence: Sendable, Codable {
    public struct Source: Sendable, Codable {
        public let sourceID: String
        public let originalSourceID: String
        public let netName: NetName
        public let layerName: String
        public let rect: NativeRoutedPEXInput.Rect
        public let sourceFacts: [NativeRoutedPEXInput.SourceFact]
    }
    public struct Band: Sendable, Codable {
        public let netName: NetName
        public let layerName: String
        public let rect: NativeRoutedPEXInput.Rect
        public let contributorIndices: [Int]
    }
    public struct Boundary: Sendable, Codable {
        public let bandIndex: Int
        public let side: String
        public let coordinate: Int32
        public let begin: Int32
        public let end: Int32
        public let contributorIndices: [Int]
    }
    public struct Cell: Sendable, Codable {
        public let netName: NetName
        public let layerName: String
        public let rect: NativeRoutedPEXInput.Rect
        public let node: NodeRef?
        public let contributorIndices: [Int]
    }
    public struct Resistance: Sendable, Codable {
        public let elementID: String
        public let contributorIndices: [Int]
        public let cutSourceID: String?
        public let originalCutSourceID: String?
    }
    public struct Attachment: Sendable, Codable {
        public enum Kind: String, Sendable, Codable { case groundArea, groundBoundary, lateralCoupling, diagonalCoupling, referenceCoupling }
        public let kind: Kind
        public let elementID: String
        public let bandIndex: Int?
        public let otherBandIndex: Int?
        public let boundaryIndex: Int?
        public let queryReceiptIndex: Int?
        public let cellA: Int
        public let cellB: Int?
        public let farads: Double
        public let longitudinalBegin: Int64?
        public let longitudinalEnd: Int64?
    }
    public let version: Int
    public let resistanceModel: String
    public let groundModel: String
    public let couplingModel: String
    public let maximumCellSpanDatabaseUnits: Int32
    public let sources: [Source]
    public let bands: [Band]
    public let boundaries: [Boundary]
    public let cells: [Cell]
    public let resistances: [Resistance]
    public let attachments: [Attachment]
}
