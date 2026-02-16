import Foundation

public struct PEXExecutionContext: Sendable {
    public let runID: PEXRunID
    public let corner: PEXCorner
    public let layoutURL: URL
    public let sourceNetlistURL: URL
    public let topCell: String
    public let technology: TechnologyIR
    public let options: PEXRunOptions
    public let workingDirectory: URL
    public let rawOutputDirectory: URL

    public init(
        runID: PEXRunID,
        corner: PEXCorner,
        layoutURL: URL,
        sourceNetlistURL: URL,
        topCell: String,
        technology: TechnologyIR,
        options: PEXRunOptions,
        workingDirectory: URL,
        rawOutputDirectory: URL
    ) {
        self.runID = runID
        self.corner = corner
        self.layoutURL = layoutURL
        self.sourceNetlistURL = sourceNetlistURL
        self.topCell = topCell
        self.technology = technology
        self.options = options
        self.workingDirectory = workingDirectory
        self.rawOutputDirectory = rawOutputDirectory
    }
}
