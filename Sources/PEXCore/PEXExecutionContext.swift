import Foundation

public struct PEXExecutionContext: Sendable {
    public typealias CancellationCheck = @Sendable () async throws -> Bool

    public let runID: PEXRunID
    public let corner: PEXCorner
    public let layoutURL: URL
    public let sourceNetlistURL: URL
    public let sourceNetlistFormat: NetlistFormat
    public let topCell: String
    public let technology: TechnologyIR
    public let processProfile: PEXProcessProfileReference?
    public let backendSelection: PEXBackendSelection
    public let options: PEXRunOptions
    public let workingDirectory: URL
    public let rawOutputDirectory: URL
    public let cancellationCheck: CancellationCheck?

    public init(
        runID: PEXRunID,
        corner: PEXCorner,
        layoutURL: URL,
        sourceNetlistURL: URL,
        sourceNetlistFormat: NetlistFormat = .spice,
        topCell: String,
        technology: TechnologyIR,
        processProfile: PEXProcessProfileReference? = nil,
        backendSelection: PEXBackendSelection = PEXBackendSelection(backendID: "unspecified"),
        options: PEXRunOptions,
        workingDirectory: URL,
        rawOutputDirectory: URL,
        cancellationCheck: CancellationCheck? = nil
    ) {
        self.runID = runID
        self.corner = corner
        self.layoutURL = layoutURL
        self.sourceNetlistURL = sourceNetlistURL
        self.sourceNetlistFormat = sourceNetlistFormat
        self.topCell = topCell
        self.technology = technology
        self.processProfile = processProfile
        self.backendSelection = backendSelection
        self.options = options
        self.workingDirectory = workingDirectory
        self.rawOutputDirectory = rawOutputDirectory
        self.cancellationCheck = cancellationCheck
    }
}
