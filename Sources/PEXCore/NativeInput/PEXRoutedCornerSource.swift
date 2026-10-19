import CircuiteFoundation

/// One explicit requested-corner association to exact original rule and technology sources.
public struct PEXRoutedCornerSource: Sendable, Codable, Hashable {
    public let cornerID: PEXCornerID
    public let selection: PEXOpenRCXSourceModel.Selection
    public let rules: ArtifactReference
    public let technologyLEF: ArtifactReference

    public init(cornerID: PEXCornerID, selection: PEXOpenRCXSourceModel.Selection,
                rules: ArtifactReference, technologyLEF: ArtifactReference) {
        self.cornerID = cornerID; self.selection = selection
        self.rules = rules; self.technologyLEF = technologyLEF
    }
}
