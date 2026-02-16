import Foundation
import PEXCore

public struct PEXConfigMapper: Sendable {
    public init() {}

    public func mapToRunRequest(
        config: PEXProjectConfig,
        configFileURL: URL
    ) throws -> PEXRunRequest {
        let baseDir = configFileURL.deletingLastPathComponent()

        let layoutURL = Self.resolveURL(config.inputs.layout, relativeTo: baseDir)
        let netlistURL = Self.resolveURL(config.inputs.netlist, relativeTo: baseDir)
        let technologyURL = Self.resolveURL(config.inputs.technology, relativeTo: baseDir)
        let workspaceURL = Self.resolveURL(config.output.workspace, relativeTo: baseDir)

        let corners = config.normalizedCorners.map { PEXCorner(id: $0) }

        let options = PEXRunOptions(
            extractMode: .rc,
            includeCouplingCaps: config.options.includeCouplingCaps,
            minCapacitanceF: config.options.minCapacitanceF,
            minResistanceOhm: config.options.minResistanceOhm,
            maxParallelJobs: config.options.maxParallelJobs,
            emitRawArtifacts: true,
            emitIRJSON: true,
            strictValidation: config.options.strictValidation
        )

        return PEXRunRequest(
            layoutURL: layoutURL,
            layoutFormat: Self.detectLayoutFormat(config.inputs.layout),
            sourceNetlistURL: netlistURL,
            sourceNetlistFormat: .spice,
            topCell: config.topCell,
            corners: corners,
            technology: .jsonFile(technologyURL),
            backendSelection: PEXBackendSelection(
                backendID: config.backendID,
                executablePath: config.executablePath
            ),
            options: options,
            workingDirectory: workspaceURL
        )
    }

    private static func resolveURL(_ path: String, relativeTo baseDir: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(filePath: path)
        }
        return baseDir.appending(path: path)
    }

    private static func detectLayoutFormat(_ path: String) -> LayoutFormat {
        let lower = path.lowercased()
        if lower.hasSuffix(".oas") || lower.hasSuffix(".oasis") {
            return .oas
        }
        return .gds
    }
}
