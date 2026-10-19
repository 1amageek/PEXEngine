import Foundation
import CircuiteFoundation

public struct PEXExecutionContext: Sendable {
    public typealias CancellationCheck = @Sendable () async throws -> Bool

    public let runID: PEXRunID
    public let corner: PEXCorner
    public let requestedCornerIDs: [PEXCornerID]
    public let layoutURL: URL
    public let layoutFormat: LayoutFormat
    public let sourceNetlistURL: URL
    public let sourceNetlistFormat: NetlistFormat
    public let topCell: String
    public let technology: TechnologyIR
    public let nativeInput: PEXNativeInputReference?
    public let executionInputArtifacts: [ArtifactReference]
    public let processProfile: PEXProcessProfileReference?
    public let backendSelection: PEXBackendSelection
    public let options: PEXRunOptions
    public let workingDirectory: URL
    public let rawOutputDirectory: URL
    public let cancellationCheck: CancellationCheck?

    public init(
        runID: PEXRunID,
        corner: PEXCorner,
        requestedCornerIDs: [PEXCornerID]? = nil,
        layoutURL: URL,
        layoutFormat: LayoutFormat = .gds,
        sourceNetlistURL: URL,
        sourceNetlistFormat: NetlistFormat = .spice,
        topCell: String,
        technology: TechnologyIR,
        nativeInput: PEXNativeInputReference? = nil,
        processProfile: PEXProcessProfileReference? = nil,
        executionInputArtifacts: [ArtifactReference] = [],
        backendSelection: PEXBackendSelection = PEXBackendSelection(backendID: "unspecified"),
        options: PEXRunOptions,
        workingDirectory: URL,
        rawOutputDirectory: URL,
        cancellationCheck: CancellationCheck? = nil
    ) {
        self.runID = runID
        self.corner = corner
        self.requestedCornerIDs = requestedCornerIDs ?? [corner.id]
        self.layoutURL = layoutURL
        self.layoutFormat = layoutFormat
        self.sourceNetlistURL = sourceNetlistURL
        self.sourceNetlistFormat = sourceNetlistFormat
        self.topCell = topCell
        self.technology = technology
        self.nativeInput = nativeInput
        self.processProfile = processProfile
        self.executionInputArtifacts = executionInputArtifacts
        self.backendSelection = backendSelection
        self.options = options
        self.workingDirectory = workingDirectory
        self.rawOutputDirectory = rawOutputDirectory
        self.cancellationCheck = cancellationCheck
    }
}
