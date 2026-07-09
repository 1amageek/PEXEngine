public struct PEXExtractorRunRequest: Sendable, Codable, Hashable {
    public let backendID: String
    public let topCell: String
    public let layoutFormat: LayoutFormat
    public let sourceNetlistFormat: NetlistFormat
    public let technology: PEXTechnologyReference
    public let processProfile: PEXProcessProfileReference?
    public let corners: [PEXExtractorCornerMetadata]
    public let options: PEXRunOptions
    public let requestedOutputFormats: [PEXOutputFormat]
    public let requestedArtifactKinds: [PEXArtifactKind]

    public init(
        backendID: String,
        topCell: String,
        layoutFormat: LayoutFormat,
        sourceNetlistFormat: NetlistFormat,
        technology: PEXTechnologyReference,
        processProfile: PEXProcessProfileReference? = nil,
        corners: [PEXExtractorCornerMetadata],
        options: PEXRunOptions,
        requestedOutputFormats: [PEXOutputFormat] = [],
        requestedArtifactKinds: [PEXArtifactKind] = [.rawOutput, .parasiticIR, .spefRoundTrip, .report]
    ) {
        self.backendID = backendID
        self.topCell = topCell
        self.layoutFormat = layoutFormat
        self.sourceNetlistFormat = sourceNetlistFormat
        self.technology = technology
        self.processProfile = processProfile
        self.corners = corners
        self.options = options
        self.requestedOutputFormats = requestedOutputFormats
        self.requestedArtifactKinds = requestedArtifactKinds
    }

    public init(
        runRequest: PEXRunRequest,
        processProfile: PEXProcessProfileReference? = nil,
        capabilities: PEXBackendCapabilities? = nil
    ) {
        self.init(
            backendID: runRequest.backendSelection.backendID,
            topCell: runRequest.topCell,
            layoutFormat: runRequest.layoutFormat,
            sourceNetlistFormat: runRequest.sourceNetlistFormat,
            technology: PEXTechnologyReference(input: runRequest.technology),
            processProfile: processProfile ?? runRequest.processProfile,
            corners: runRequest.corners.map(PEXExtractorCornerMetadata.init(corner:)),
            options: runRequest.options,
            requestedOutputFormats: capabilities?.nativeOutputFormats ?? [],
            requestedArtifactKinds: [.rawOutput, .parasiticIR, .spefRoundTrip, .report]
        )
    }
}
