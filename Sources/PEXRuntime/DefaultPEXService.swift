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
            sourceNetlistFormat: selection.sourceNetlistFormat,
            topCell: selection.topCell,
            corners: corners,
            technology: .jsonFile(selection.technologyPath),
            technologyByCorner: selection.technologyByCornerPaths.mapValues(TechnologyInput.jsonFile),
            processProfile: selection.processProfile,
            backendSelection: backend,
            options: selection.options,
            workingDirectory: selection.workingDirectory
        )
        return try await engine.run(request)
    }

    public func loadRun(_ runID: PEXRunID, workspace: URL) throws -> PEXRunResult {
        let ws = PEXRunWorkspace(baseURL: workspace, runID: runID)
        let store = PEXArtifactStore(workspace: ws)
        return try store.loadResult()
    }

    public func loadLineage(_ runID: PEXRunID, workspace: URL) throws -> PEXRunLineage {
        let ws = PEXRunWorkspace(baseURL: workspace, runID: runID)
        let store = PEXArtifactStore(workspace: ws)
        return try store.loadLineage()
    }

    public func queryNet(
        _ net: NetName,
        runID: PEXRunID,
        corner: PEXCornerID,
        workspace: URL
    ) throws -> NetParasiticSummary {
        let ws = PEXRunWorkspace(baseURL: workspace, runID: runID)
        let resolver = try PEXArtifactResolver(workspace: ws)
        let ir = try resolver.loadIR(cornerID: corner)

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

    public func moduleSummary(
        _ module: InstancePath,
        runID: PEXRunID,
        corner: PEXCornerID,
        workspace: URL
    ) throws -> PEXModuleParasiticSummary {
        let ir = try loadIR(runID: runID, corner: corner, workspace: workspace)
        let moduleValue = module.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !moduleValue.isEmpty else {
            throw PEXError.invalidInput("Module path must not be empty")
        }

        // A number of extractors do not annotate top-level ports with an
        // instance path. Treat those unscoped nodes as belonging to the root
        // design only when the requested path matches the design identity.
        // They must not be attributed to an arbitrary child module because
        // that would turn missing hierarchy provenance into a false positive.
        let designRoot = (ir.metadata["topCell"] ?? ir.metadata["designName"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isRootQuery = !designRoot.isEmpty && moduleValue == designRoot
        let selectedNets = ir.nets.filter { net in
            net.nodes.contains { node in
                guard let instancePath = node.instancePath?.value else {
                    return isRootQuery
                }
                return instancePath == moduleValue || instancePath.hasPrefix(moduleValue + "/")
            }
        }
        guard !selectedNets.isEmpty else {
            throw PEXError.invalidInput(
                "Module '\(moduleValue)' not found in IR for corner \(corner.value)"
            )
        }

        let selectedNetNames = Set(selectedNets.map(\.name))
        let elementCount = ir.elements.reduce(into: 0) { count, element in
            if selectedNetNames.contains(element.nodeA.netName)
                || element.nodeB.map({ selectedNetNames.contains($0.netName) }) == true {
                count += 1
            }
        }
        return PEXModuleParasiticSummary(
            modulePath: module,
            cornerID: corner,
            netNames: selectedNets.map(\.name).sorted { $0.value < $1.value },
            totalGroundCapF: selectedNets.reduce(0) { $0 + $1.totalGroundCapF },
            totalCouplingCapF: selectedNets.reduce(0) { $0 + $1.totalCouplingCapF },
            totalResistanceOhm: selectedNets.reduce(0) { $0 + $1.totalResistanceOhm },
            nodeCount: selectedNets.reduce(0) { $0 + $1.nodes.count },
            elementCount: elementCount
        )
    }

    public func cornerDelta(
        runID: PEXRunID,
        baseCorner: PEXCornerID,
        targetCorner: PEXCornerID,
        workspace: URL
    ) throws -> PEXCornerDelta {
        let baseIR = try loadIR(runID: runID, corner: baseCorner, workspace: workspace)
        let targetIR = try loadIR(runID: runID, corner: targetCorner, workspace: workspace)
        let baseNets = Dictionary(uniqueKeysWithValues: baseIR.nets.map { ($0.name, $0) })
        let targetNets = Dictionary(uniqueKeysWithValues: targetIR.nets.map { ($0.name, $0) })
        let allNames = Set(baseNets.keys).union(targetNets.keys).sorted { $0.value < $1.value }
        let deltas = allNames.map { name in
            let base = baseNets[name]
            let target = targetNets[name]
            return PEXNetParasiticDelta(
                netName: name,
                groundCapDeltaF: (target?.totalGroundCapF ?? 0) - (base?.totalGroundCapF ?? 0),
                couplingCapDeltaF: (target?.totalCouplingCapF ?? 0) - (base?.totalCouplingCapF ?? 0),
                resistanceDeltaOhm: (target?.totalResistanceOhm ?? 0) - (base?.totalResistanceOhm ?? 0),
                baseNodeCount: base?.nodes.count ?? 0,
                targetNodeCount: target?.nodes.count ?? 0
            )
        }
        return PEXCornerDelta(
            baseCornerID: baseCorner,
            targetCornerID: targetCorner,
            totalGroundCapDeltaF: total(targetIR, keyPath: \.totalGroundCapF) - total(baseIR, keyPath: \.totalGroundCapF),
            totalCouplingCapDeltaF: total(targetIR, keyPath: \.totalCouplingCapF) - total(baseIR, keyPath: \.totalCouplingCapF),
            totalResistanceDeltaOhm: total(targetIR, keyPath: \.totalResistanceOhm) - total(baseIR, keyPath: \.totalResistanceOhm),
            netDeltas: deltas
        )
    }

    private func loadIR(runID: PEXRunID, corner: PEXCornerID, workspace: URL) throws -> ParasiticIR {
        let ws = PEXRunWorkspace(baseURL: workspace, runID: runID)
        let resolver = try PEXArtifactResolver(workspace: ws)
        return try resolver.loadIR(cornerID: corner)
    }

    private func total(_ ir: ParasiticIR, keyPath: KeyPath<ParasiticNet, Double>) -> Double {
        ir.nets.reduce(0) { $0 + $1[keyPath: keyPath] }
    }

    private func detectLayoutFormat(_ url: URL) -> LayoutFormat {
        let ext = url.pathExtension.lowercased()
        if ext == "def" {
            return .def
        }
        if ext == "oas" || ext == "oasis" {
            return .oas
        }
        return .gds
    }
}
