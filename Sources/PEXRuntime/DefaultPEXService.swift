import Foundation
import PEXCore
import PEXPersistence

public struct DefaultPEXService: PEXService, Sendable {
    private let engine: DefaultPEXEngine

    public init(engine: DefaultPEXEngine) {
        self.engine = engine
    }

    public static func withDefaults() -> DefaultPEXService {
        DefaultPEXService(engine: DefaultPEXEngine.withDefaults())
    }

    public func extract(
        for selection: LayoutSelection,
        corners: [PEXCorner],
        backend: PEXBackendSelection
    ) async throws -> PEXRunResult {
        let request = PEXRunRequest(
            layoutURL: selection.layoutURL,
            layoutFormat: detectLayoutFormat(selection.layoutURL),
            sourceNetlistURL: selection.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: selection.topCell,
            corners: corners,
            technology: .jsonFile(selection.technologyPath),
            backendSelection: backend,
            options: .default
        )
        return try await engine.run(request)
    }

    public func loadRun(_ runID: PEXRunID, workspace: URL) throws -> PEXRunResult {
        let ws = PEXRunWorkspace(baseURL: workspace, runID: runID)
        let store = PEXArtifactStore(workspace: ws)
        let manifest = try store.loadManifest()
        let cornerIDs = manifest.corners.map(\.cornerID)
        return try store.loadResult(cornerIDs: cornerIDs, manifest: manifest)
    }

    public func queryNet(
        _ net: NetName,
        runID: PEXRunID,
        corner: PEXCornerID,
        workspace: URL
    ) throws -> NetParasiticSummary {
        let ws = PEXRunWorkspace(baseURL: workspace, runID: runID)
        let store = PEXArtifactStore(workspace: ws)
        let ir = try store.loadIR(for: corner)

        guard let parasiticNet = ir.nets.first(where: { $0.name == net }) else {
            throw PEXError.invalidInput("Net '\(net.value)' not found in IR for corner \(corner.value)")
        }

        return NetParasiticSummary(
            netName: net,
            cornerID: corner,
            totalGroundCapF: parasiticNet.totalGroundCapF,
            totalCouplingCapF: parasiticNet.totalCouplingCapF,
            totalResistanceOhm: parasiticNet.totalResistanceOhm,
            nodeCount: parasiticNet.nodes.count,
            elementCount: ir.elements.filter { $0.nodeA.netName == net || $0.nodeB?.netName == net }.count
        )
    }

    private func detectLayoutFormat(_ url: URL) -> LayoutFormat {
        let ext = url.pathExtension.lowercased()
        if ext == "oas" || ext == "oasis" {
            return .oas
        }
        return .gds
    }
}
