import Foundation
import PEXCore

public struct PEXConfigMapper: Sendable {
    private let nativeInputLoader: any PEXNativeInputLoading

    public init(nativeInputLoader: any PEXNativeInputLoading = PEXNativeInputLoader()) {
        self.nativeInputLoader = nativeInputLoader
    }

    public func mapToRunRequest(
        config: PEXProjectConfig,
        configFileURL: URL
    ) throws -> PEXRunRequest {
        let baseDir = configFileURL.deletingLastPathComponent()

        let layoutURL = Self.resolveURL(config.inputs.layout, relativeTo: baseDir)
        let netlistURL = Self.resolveURL(config.inputs.netlist, relativeTo: baseDir)
        let technologyURL = Self.resolveURL(config.inputs.technology, relativeTo: baseDir)
        let technologyByCorner = config.inputs.technologyByCorner.reduce(into: [String: TechnologyInput]()) { result, entry in
            result[entry.key] = .jsonFile(Self.resolveURL(entry.value, relativeTo: baseDir))
        }
        let processProfile = config.processProfile.map { profile in
            PEXProcessProfileReference(
                profileID: profile.profileID,
                pdkID: profile.pdkID,
                source: profile.source,
                requirementID: profile.requirementID,
                pdkRoot: Self.resolveOptionalPath(profile.pdkRoot, relativeTo: baseDir),
                primaryDeckPath: Self.resolveOptionalPath(profile.primaryDeckPath, relativeTo: baseDir),
                cornerDeckPaths: profile.cornerDeckPaths.reduce(into: [String: String]()) { result, entry in
                    result[entry.key] = Self.resolvePath(entry.value, relativeTo: baseDir).path(percentEncoded: false)
                },
                requiredViewPaths: profile.requiredViewPaths.reduce(into: [String: String]()) { result, entry in
                    result[entry.key] = Self.resolvePath(entry.value, relativeTo: baseDir).path(percentEncoded: false)
                },
                metadata: profile.metadata
            )
        }
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
            strictValidation: config.options.strictValidation,
            sourceConnectivityPolicy: config.options.sourceConnectivityPolicy
        )

        let backendID = try Self.requiredBackendID(config.backendID)
        let nativeInputURL = try config.inputs.nativeInput.map { path in
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PEXError.invalidInput("Configuration inputs.nativeInput must not be empty")
            }
            return Self.resolveURL(path, relativeTo: baseDir)
        }
        let nativeInput = try nativeInputLoader.load(backendID: backendID, referenceURL: nativeInputURL)

        return PEXRunRequest(
            layoutURL: layoutURL,
            layoutFormat: Self.detectLayoutFormat(config.inputs.layout),
            sourceNetlistURL: netlistURL,
            sourceNetlistFormat: config.inputs.sourceNetlistFormat,
            topCell: config.topCell,
            corners: corners,
            technology: .jsonFile(technologyURL),
            technologyByCorner: technologyByCorner,
            nativeInput: nativeInput,
            processProfile: processProfile,
            backendSelection: PEXBackendSelection(
                backendID: backendID,
                executablePath: Self.resolveOptionalPath(config.executablePath, relativeTo: baseDir)
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

    private static func resolveOptionalPath(_ path: String?, relativeTo baseDir: URL) -> String? {
        guard let path else {
            return nil
        }
        return resolvePath(path, relativeTo: baseDir).path(percentEncoded: false)
    }

    private static func resolvePath(_ path: String, relativeTo baseDir: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(filePath: path)
        }
        return baseDir.appending(path: path)
    }

    private static func detectLayoutFormat(_ path: String) -> LayoutFormat {
        let lower = path.lowercased()
        if lower.hasSuffix(".def") {
            return .def
        }
        if lower.hasSuffix(".oas") || lower.hasSuffix(".oasis") {
            return .oas
        }
        return .gds
    }

    private static func requiredBackendID(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PEXError.invalidInput("backendID is required in PEXProjectConfig")
        }
        return trimmed
    }
}
