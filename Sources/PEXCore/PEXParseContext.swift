public struct PEXParseContext: Sendable {
    public let cornerID: PEXCornerID
    public let runID: PEXRunID
    public let topCell: String?
    public let technology: TechnologyIR?
    public let options: PEXRunOptions

    public init(
        cornerID: PEXCornerID,
        runID: PEXRunID,
        topCell: String? = nil,
        technology: TechnologyIR?,
        options: PEXRunOptions
    ) {
        self.cornerID = cornerID
        self.runID = runID
        self.topCell = topCell
        self.technology = technology
        self.options = options
    }
}
