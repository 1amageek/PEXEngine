public struct PEXParseContext: Sendable {
    public let cornerID: PEXCornerID
    public let runID: PEXRunID
    public let technology: TechnologyIR?
    public let options: PEXRunOptions

    public init(cornerID: PEXCornerID, runID: PEXRunID, technology: TechnologyIR?, options: PEXRunOptions) {
        self.cornerID = cornerID
        self.runID = runID
        self.technology = technology
        self.options = options
    }
}
