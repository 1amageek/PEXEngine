import Foundation

public struct PEXRunRequest: Sendable, Codable, Hashable {
    public let layoutURL: URL
    public let layoutFormat: LayoutFormat
    public let sourceNetlistURL: URL
    public let sourceNetlistFormat: NetlistFormat
    public let topCell: String
    public let corners: [PEXCorner]
    public let technology: TechnologyInput
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
        self.backendSelection = backendSelection
        self.options = options
        self.workingDirectory = workingDirectory
    }
}
