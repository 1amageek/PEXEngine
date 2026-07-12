import Foundation

public struct PEXRunRequest: Sendable, Codable, Hashable {
    public let layoutURL: URL
    public let layoutFormat: LayoutFormat
    public let sourceNetlistURL: URL
    public let sourceNetlistFormat: NetlistFormat
    public let topCell: String
    public let corners: [PEXCorner]
    public let technology: TechnologyInput
    /// Optional per-corner technology overrides. Corners not present in this
    /// map use the run-level technology reference.
    public let technologyByCorner: [String: TechnologyInput]
    public let processProfile: PEXProcessProfileReference?
    public let backendSelection: PEXBackendSelection
    public let options: PEXRunOptions
    public let workingDirectory: URL?

    public init(
        layoutURL: URL,
        layoutFormat: LayoutFormat,
        sourceNetlistURL: URL,
        sourceNetlistFormat: NetlistFormat,
        topCell: String,
        corners: [PEXCorner],
        technology: TechnologyInput,
        technologyByCorner: [String: TechnologyInput] = [:],
        processProfile: PEXProcessProfileReference? = nil,
        backendSelection: PEXBackendSelection,
        options: PEXRunOptions,
        workingDirectory: URL? = nil
    ) {
        self.layoutURL = layoutURL
        self.layoutFormat = layoutFormat
        self.sourceNetlistURL = sourceNetlistURL
        self.sourceNetlistFormat = sourceNetlistFormat
        self.topCell = topCell
        self.corners = corners
        self.technology = technology
        self.technologyByCorner = technologyByCorner
        self.processProfile = processProfile
        self.backendSelection = backendSelection
        self.options = options
        self.workingDirectory = workingDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case layoutURL
        case layoutFormat
        case sourceNetlistURL
        case sourceNetlistFormat
        case topCell
        case corners
        case technology
        case technologyByCorner
        case processProfile
        case backendSelection
        case options
        case workingDirectory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.layoutURL = try container.decode(URL.self, forKey: .layoutURL)
        self.layoutFormat = try container.decode(LayoutFormat.self, forKey: .layoutFormat)
        self.sourceNetlistURL = try container.decode(URL.self, forKey: .sourceNetlistURL)
        self.sourceNetlistFormat = try container.decode(NetlistFormat.self, forKey: .sourceNetlistFormat)
        self.topCell = try container.decode(String.self, forKey: .topCell)
        self.corners = try container.decode([PEXCorner].self, forKey: .corners)
        self.technology = try container.decode(TechnologyInput.self, forKey: .technology)
        self.technologyByCorner = try container.decodeIfPresent(
            [String: TechnologyInput].self,
            forKey: .technologyByCorner
        ) ?? [:]
        self.processProfile = try container.decodeIfPresent(
            PEXProcessProfileReference.self,
            forKey: .processProfile
        )
        self.backendSelection = try container.decode(PEXBackendSelection.self, forKey: .backendSelection)
        self.options = try container.decode(PEXRunOptions.self, forKey: .options)
        self.workingDirectory = try container.decodeIfPresent(URL.self, forKey: .workingDirectory)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layoutURL, forKey: .layoutURL)
        try container.encode(layoutFormat, forKey: .layoutFormat)
        try container.encode(sourceNetlistURL, forKey: .sourceNetlistURL)
        try container.encode(sourceNetlistFormat, forKey: .sourceNetlistFormat)
        try container.encode(topCell, forKey: .topCell)
        try container.encode(corners, forKey: .corners)
        try container.encode(technology, forKey: .technology)
        try container.encode(technologyByCorner, forKey: .technologyByCorner)
        try container.encodeIfPresent(processProfile, forKey: .processProfile)
        try container.encode(backendSelection, forKey: .backendSelection)
        try container.encode(options, forKey: .options)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
    }
}
