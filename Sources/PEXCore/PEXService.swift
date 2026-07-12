import Foundation

public protocol PEXService: Sendable {
    func extract(
        for selection: LayoutSelection,
        corners: [PEXCorner],
        backend: PEXBackendSelection
    ) async throws -> PEXRunResult

    func loadRun(_ runID: PEXRunID, workspace: URL) throws -> PEXRunResult

    func loadLineage(_ runID: PEXRunID, workspace: URL) throws -> PEXRunLineage

    func queryNet(_ net: NetName, runID: PEXRunID, corner: PEXCornerID, workspace: URL) throws -> NetParasiticSummary

    func moduleSummary(
        _ module: InstancePath,
        runID: PEXRunID,
        corner: PEXCornerID,
        workspace: URL
    ) throws -> PEXModuleParasiticSummary

    func cornerDelta(
        runID: PEXRunID,
        baseCorner: PEXCornerID,
        targetCorner: PEXCornerID,
        workspace: URL
    ) throws -> PEXCornerDelta
}

public extension PEXService {
    func loadLineage(_ runID: PEXRunID, workspace: URL) throws -> PEXRunLineage {
        throw PEXError.internalInvariantViolation(
            "This PEXService implementation does not provide run lineage"
        )
    }

    func moduleSummary(
        _ module: InstancePath,
        runID: PEXRunID,
        corner: PEXCornerID,
        workspace: URL
    ) throws -> PEXModuleParasiticSummary {
        throw PEXError.internalInvariantViolation(
            "This PEXService implementation does not provide module summaries"
        )
    }

    func cornerDelta(
        runID: PEXRunID,
        baseCorner: PEXCornerID,
        targetCorner: PEXCornerID,
        workspace: URL
    ) throws -> PEXCornerDelta {
        throw PEXError.internalInvariantViolation(
            "This PEXService implementation does not provide corner deltas"
        )
    }
}

public struct LayoutSelection: Sendable, Codable, Hashable {
    public let layoutURL: URL
    public let netlistURL: URL
    public let topCell: String
    public let technologyPath: URL
    public let technologyByCornerPaths: [String: URL]
    public let sourceNetlistFormat: NetlistFormat
    public let processProfile: PEXProcessProfileReference?
    public let options: PEXRunOptions
    public let workingDirectory: URL?

    public init(
        layoutURL: URL,
        netlistURL: URL,
        topCell: String,
        technologyPath: URL,
        technologyByCornerPaths: [String: URL] = [:],
        sourceNetlistFormat: NetlistFormat = .spice,
        processProfile: PEXProcessProfileReference? = nil,
        options: PEXRunOptions = .default,
        workingDirectory: URL? = nil
    ) {
        self.layoutURL = layoutURL
        self.netlistURL = netlistURL
        self.topCell = topCell
        self.technologyPath = technologyPath
        self.technologyByCornerPaths = technologyByCornerPaths
        self.sourceNetlistFormat = sourceNetlistFormat
        self.processProfile = processProfile
        self.options = options
        self.workingDirectory = workingDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case layoutURL
        case netlistURL
        case topCell
        case technologyPath
        case technologyByCornerPaths
        case sourceNetlistFormat
        case processProfile
        case options
        case workingDirectory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.layoutURL = try container.decode(URL.self, forKey: .layoutURL)
        self.netlistURL = try container.decode(URL.self, forKey: .netlistURL)
        self.topCell = try container.decode(String.self, forKey: .topCell)
        self.technologyPath = try container.decode(URL.self, forKey: .technologyPath)
        self.technologyByCornerPaths = try container.decodeIfPresent(
            [String: URL].self,
            forKey: .technologyByCornerPaths
        ) ?? [:]
        self.sourceNetlistFormat = try container.decodeIfPresent(
            NetlistFormat.self,
            forKey: .sourceNetlistFormat
        ) ?? .spice
        self.processProfile = try container.decodeIfPresent(
            PEXProcessProfileReference.self,
            forKey: .processProfile
        )
        self.options = try container.decodeIfPresent(PEXRunOptions.self, forKey: .options) ?? .default
        self.workingDirectory = try container.decodeIfPresent(URL.self, forKey: .workingDirectory)
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
