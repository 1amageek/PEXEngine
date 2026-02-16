import Foundation

public protocol PEXService: Sendable {
    func extract(
        for selection: LayoutSelection,
        corners: [PEXCorner],
        backend: PEXBackendSelection
    ) async throws -> PEXRunResult

    func loadRun(_ runID: PEXRunID, workspace: URL) throws -> PEXRunResult

    func queryNet(_ net: NetName, runID: PEXRunID, corner: PEXCornerID, workspace: URL) throws -> NetParasiticSummary
}

public struct LayoutSelection: Sendable, Codable, Hashable {
    public let layoutURL: URL
    public let netlistURL: URL
    public let topCell: String
    public let technologyPath: URL

    public init(layoutURL: URL, netlistURL: URL, topCell: String, technologyPath: URL) {
        self.layoutURL = layoutURL
        self.netlistURL = netlistURL
        self.topCell = topCell
        self.technologyPath = technologyPath
    }
}

public struct NetParasiticSummary: Sendable, Codable, Hashable {
    public let netName: NetName
    public let cornerID: PEXCornerID
    public let totalGroundCapF: Double
    public let totalCouplingCapF: Double
    public let totalResistanceOhm: Double
    public let nodeCount: Int
    public let elementCount: Int

    public init(
        netName: NetName, cornerID: PEXCornerID,
        totalGroundCapF: Double, totalCouplingCapF: Double, totalResistanceOhm: Double,
        nodeCount: Int, elementCount: Int
    ) {
        self.netName = netName
        self.cornerID = cornerID
        self.totalGroundCapF = totalGroundCapF
        self.totalCouplingCapF = totalCouplingCapF
        self.totalResistanceOhm = totalResistanceOhm
        self.nodeCount = nodeCount
        self.elementCount = elementCount
    }
}
