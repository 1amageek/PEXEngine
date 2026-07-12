public struct PEXExtractorRunRequest: Sendable, Codable, Hashable {
    public let backendID: String
    public let topCell: String
    public let layoutFormat: LayoutFormat
    public let sourceNetlistFormat: NetlistFormat
    public let technology: PEXTechnologyReference
    public let technologyByCorner: [String: PEXTechnologyReference]
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
        technologyByCorner: [String: PEXTechnologyReference] = [:],
        processProfile: PEXProcessProfileReference? = nil,
        corners: [PEXExtractorCornerMetadata],
        options: PEXRunOptions,
        requestedOutputFormats: [PEXOutputFormat] = [],
        requestedArtifactKinds: [PEXArtifactKind] = [.rawOutput, .parasiticIR, .spefRoundTrip, .spiceBackannotation, .report]
    ) {
        self.backendID = backendID
        self.topCell = topCell
        self.layoutFormat = layoutFormat
        self.sourceNetlistFormat = sourceNetlistFormat
        self.technology = technology
        self.technologyByCorner = technologyByCorner
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
            technologyByCorner: runRequest.technologyByCorner.mapValues(PEXTechnologyReference.init(input:)),
            processProfile: processProfile ?? runRequest.processProfile,
            corners: runRequest.corners.map(PEXExtractorCornerMetadata.init(corner:)),
            options: runRequest.options,
            requestedOutputFormats: capabilities?.nativeOutputFormats ?? [],
            requestedArtifactKinds: [.rawOutput, .parasiticIR, .spefRoundTrip, .spiceBackannotation, .report]
        )
    }

    private enum CodingKeys: String, CodingKey {
        case backendID
        case topCell
        case layoutFormat
        case sourceNetlistFormat
        case technology
        case technologyByCorner
        case processProfile
        case corners
        case options
        case requestedOutputFormats
        case requestedArtifactKinds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.backendID = try container.decode(String.self, forKey: .backendID)
        self.topCell = try container.decode(String.self, forKey: .topCell)
        self.layoutFormat = try container.decode(LayoutFormat.self, forKey: .layoutFormat)
        self.sourceNetlistFormat = try container.decode(NetlistFormat.self, forKey: .sourceNetlistFormat)
        self.technology = try container.decode(PEXTechnologyReference.self, forKey: .technology)
        self.technologyByCorner = try container.decodeIfPresent(
            [String: PEXTechnologyReference].self,
            forKey: .technologyByCorner
        ) ?? [:]
        self.processProfile = try container.decodeIfPresent(
            PEXProcessProfileReference.self,
            forKey: .processProfile
        )
        self.corners = try container.decode([PEXExtractorCornerMetadata].self, forKey: .corners)
        self.options = try container.decode(PEXRunOptions.self, forKey: .options)
        self.requestedOutputFormats = try container.decodeIfPresent(
            [PEXOutputFormat].self,
            forKey: .requestedOutputFormats
        ) ?? []
        self.requestedArtifactKinds = try container.decodeIfPresent(
            [PEXArtifactKind].self,
            forKey: .requestedArtifactKinds
        ) ?? [.rawOutput, .parasiticIR, .spefRoundTrip, .spiceBackannotation, .report]
    }
}
