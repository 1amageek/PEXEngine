import Foundation
import CircuiteFoundation
import PEXCore

public struct PEXArtifactStore: Sendable {
    public let workspace: PEXRunWorkspace
    private let serializer: PEXIRSerializer

    public init(workspace: PEXRunWorkspace) {
        self.workspace = workspace
        self.serializer = PEXIRSerializer()
    }

    public func saveManifest(_ manifest: PEXArtifactManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(manifest)
        } catch {
            throw PEXError.persistenceFailed("Failed to encode artifact manifest", underlying: error)
        }
        do {
            try data.write(to: workspace.manifestURL)
        } catch {
            throw PEXError.persistenceFailed("Failed to write artifact manifest to \(workspace.manifestURL.path(percentEncoded: false))", underlying: error)
        }
    }

    public func loadManifest() throws -> PEXArtifactManifest {
        let data: Data
        do {
            data = try Data(contentsOf: workspace.manifestURL)
        } catch {
            throw PEXError.persistenceFailed("Failed to read artifact manifest from \(workspace.manifestURL.path(percentEncoded: false))", underlying: error)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let manifest = try decoder.decode(PEXArtifactManifest.self, from: data)
            guard manifest.version == PEXArtifactManifest.currentVersion else {
                throw PEXError.persistenceFailed("Unsupported PEX artifact manifest version \(manifest.version)")
            }
            return manifest
        } catch let error as PEXError {
            throw error
        } catch {
            throw PEXError.persistenceFailed("Failed to decode artifact manifest", underlying: error)
        }
    }

    public func saveRequest(_ request: PEXRunRequest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(request)
        } catch {
            throw PEXError.persistenceFailed("Failed to encode request", underlying: error)
        }
        do {
            try data.write(to: workspace.requestURL)
        } catch {
            throw PEXError.persistenceFailed("Failed to write request", underlying: error)
        }
    }

    public func saveIR(_ ir: ParasiticIR, for cornerID: PEXCornerID) throws {
        let data = try serializer.encode(ir)
        let url = workspace.cornerIRURL(cornerID)
        do {
            try data.write(to: url)
        } catch {
            throw PEXError.persistenceFailed("Failed to write IR for corner \(cornerID)", underlying: error)
        }
    }

    public func loadIR(for cornerID: PEXCornerID) throws -> ParasiticIR {
        let resolver = try PEXArtifactResolver(workspace: workspace)
        return try resolver.loadIR(cornerID: cornerID)
    }

    public func saveReport(_ report: String) throws {
        let data = Data(report.utf8)
        do {
            try data.write(to: workspace.reportURL)
        } catch {
            throw PEXError.persistenceFailed("Failed to write report", underlying: error)
        }
    }

    /// Reconstructs a runnable request exclusively from the captured inputs of
    /// this run. The returned request points at immutable run-local copies, so
    /// retry/resume does not depend on the original source paths remaining
    /// available.
    public func loadRequest() throws -> PEXRunRequest {
        let manifest = try loadManifest()
        let resolver = try PEXArtifactResolver(workspace: workspace, manifest: manifest)
        let completeness = resolver.completenessReport()
        guard completeness.status != .invalid else {
            let details = completeness.issues.map(\.message).joined(separator: "; ")
            throw PEXError.persistenceFailed("Artifact manifest integrity validation failed: \(details)")
        }

        guard let requestRecord = resolver.records(kind: .request, availability: .available).first else {
            throw PEXError.persistenceFailed("Run does not contain a captured request artifact")
        }
        let requestURL = try resolver.validatedURL(for: requestRecord)
        let requestData: Data
        do {
            requestData = try Data(contentsOf: requestURL)
        } catch {
            throw PEXError.persistenceFailed("Failed to read captured request artifact", underlying: error)
        }
        let captured: PEXCapturedRunRequest
        do {
            captured = try JSONDecoder().decode(PEXCapturedRunRequest.self, from: requestData)
        } catch {
            throw PEXError.persistenceFailed("Failed to decode captured request artifact", underlying: error)
        }

        let inputArtifactIDs = try captured.inputArtifactIDs.map(ArtifactID.init(rawValue:))
        let inputRecords = inputArtifactIDs.compactMap { manifest.artifact(id: $0) }
        guard let layoutRecord = inputRecords.first(where: {
                  $0.matches(kind: .layoutInput) && $0.availability == .available
              }),
              let netlistRecord = inputRecords.first(where: {
                  $0.matches(kind: .netlistInput) && $0.availability == .available
              }) else {
            throw PEXError.persistenceFailed("Captured request is missing layout or source-netlist inputs")
        }
        let layoutURL = try resolver.validatedURL(for: layoutRecord)
        let netlistURL = try resolver.validatedURL(for: netlistRecord)
        let technologyRecord = inputRecords.first(where: {
            $0.matches(kind: .technologyInput) && $0.availability == .available
        })

        let technology: TechnologyInput
        switch captured.technology {
        case .jsonFile:
            guard let technologyRecord else {
                throw PEXError.persistenceFailed("Captured JSON technology input is missing")
            }
            technology = .jsonFile(try resolver.validatedURL(for: technologyRecord))
        case .inline(let value):
            technology = .inline(value)
        }

        var technologyByCorner: [String: TechnologyInput] = [:]
        for cornerID in captured.technologyByCorner.keys.sorted() {
            guard let capturedInput = captured.technologyByCorner[cornerID] else { continue }
            technologyByCorner[cornerID] = try resolveCapturedTechnology(
                capturedInput,
                inputRecords: inputRecords,
                resolver: resolver,
                label: "corner '(cornerID)'"
            )
        }

        let processProfile = try captured.processProfile.map {
            try resolveProcessProfile($0, inputRecords: inputRecords, resolver: resolver)
        }
        return PEXRunRequest(
            layoutURL: layoutURL,
            layoutFormat: captured.layoutFormat,
            sourceNetlistURL: netlistURL,
            sourceNetlistFormat: captured.sourceNetlistFormat,
            topCell: captured.topCell,
            corners: captured.corners,
            technology: technology,
            technologyByCorner: technologyByCorner,
            processProfile: processProfile,
            backendSelection: captured.backendSelection,
            options: captured.options,
            workingDirectory: workspace.baseURL,
            executionInputArtifacts: captured.executionInputArtifacts
        )
    }

    private func resolveCapturedTechnology(
        _ input: TechnologyInput,
        inputRecords: [PEXArtifactRecord],
        resolver: PEXArtifactResolver,
        label: String
    ) throws -> TechnologyInput {
        switch input {
        case .inline:
            return input
        case .jsonFile(let capturedURL):
            let normalizedCapturedURL = capturedURL.standardizedFileURL
            guard let record = inputRecords.first(where: { record in
                guard record.matches(kind: .technologyInput), record.availability == .available else { return false }
                let recordURL = workspace.runDirectory.appending(path: record.locator.location.value)
                return recordURL.standardizedFileURL == normalizedCapturedURL
            }) else {
                throw PEXError.persistenceFailed(
                    "Captured technology input for (label) is not present in the manifest"
                )
            }
            return .jsonFile(try resolver.validatedURL(for: record))
        }
    }

    public func loadResult(manifest: PEXArtifactManifest? = nil) throws -> PEXRunResult {
        let manifest = try manifest ?? loadManifest()
        let resolver = try PEXArtifactResolver(workspace: workspace, manifest: manifest)
        let completeness = resolver.completenessReport()
        if completeness.status == .invalid {
            let details = completeness.issues.map(\.message).joined(separator: "; ")
            throw PEXError.persistenceFailed("Artifact manifest integrity validation failed: \(details)")
        }
        var cornerResults: [PEXCornerResult] = []

        for corner in manifest.corners {
            let rawOutputURLs = try resolver.records(kind: .rawOutput, cornerID: corner.cornerID, availability: .available)
                .map { try resolver.validatedURL(for: $0) }
            let logURL: URL?
            if let logRecord = resolver.records(kind: .log, cornerID: corner.cornerID, availability: .available).first {
                logURL = try resolver.validatedURL(for: logRecord)
            } else {
                logURL = nil
            }
            let ir: ParasiticIR?
            if resolver.records(kind: .parasiticIR, cornerID: corner.cornerID, availability: .available).isEmpty {
                ir = nil
            } else {
                ir = try resolver.loadIR(cornerID: corner.cornerID)
            }
            cornerResults.append(PEXCornerResult(
                cornerID: corner.cornerID,
                status: corner.status,
                ir: ir,
                rawOutputURLs: rawOutputURLs,
                logURL: logURL,
                warnings: [],
                metrics: PEXCornerMetrics(
                    durationSeconds: 0,
                    netCount: ir?.nets.count ?? 0,
                    elementCount: ir?.elements.count ?? 0
                )
            ))
        }

        let successCount = cornerResults.filter { $0.status == .success }.count
        let failureCount = cornerResults.filter { $0.status == .failed }.count

        return try PEXRunResult(
            runID: manifest.runID,
            requestHash: manifest.requestHash,
            status: manifest.status,
            startedAt: manifest.startedAt,
            finishedAt: manifest.finishedAt,
            cornerResults: cornerResults,
            warnings: manifest.warnings,
            artifactManifest: manifest,
            manifestURL: workspace.manifestURL,
            metrics: PEXRunMetrics(
                totalDurationSeconds: manifest.finishedAt.timeIntervalSince(manifest.startedAt),
                cornerCount: manifest.corners.count,
                successCount: successCount,
                failureCount: failureCount
            ),
            extractorRun: manifest.extractorRun,
            resumedFromRunID: manifest.resumedFromRunID
        )
    }

    /// Loads the complete parent-to-leaf retry history and computes an
    /// effective corner view without copying or mutating any run artifacts.
    public func loadLineage() throws -> PEXRunLineage {
        var currentResult = try loadResult()
        var visited: Set<PEXRunID> = []
        var results: [PEXRunResult] = []

        while true {
            guard visited.insert(currentResult.runID).inserted else {
                throw PEXError.persistenceFailed("PEX run lineage contains a parent cycle at \(currentResult.runID)")
            }
            results.append(currentResult)
            guard let parentRunID = currentResult.resumedFromRunID else {
                break
            }

            let parentWorkspace = PEXRunWorkspace(baseURL: workspace.baseURL, runID: parentRunID)
            let parentResult = try PEXArtifactStore(workspace: parentWorkspace).loadResult()
            guard parentResult.runID == parentRunID else {
                throw PEXError.persistenceFailed(
                    "PEX parent manifest run ID \(parentResult.runID) does not match \(parentRunID)"
                )
            }
            currentResult = parentResult
        }

        return PEXRunLineage(results: results.reversed())
    }

    private func resolveProcessProfile(
        _ profile: PEXProcessProfileReference,
        inputRecords: [PEXArtifactRecord],
        resolver: PEXArtifactResolver
    ) throws -> PEXProcessProfileReference {
        func capturedPath(_ originalPath: String?) throws -> String? {
            guard let originalPath else { return nil }
            guard let record = inputRecords.first(where: {
                $0.matches(kind: .processProfileDeckInput)
                    && $0.availability == .available
                    && $0.provenance?.sourcePath == originalPath
            }) else {
                throw PEXError.persistenceFailed(
                    "Captured process-profile deck is missing for \(originalPath)"
                )
            }
            return try resolver.validatedURL(for: record).path(percentEncoded: false)
        }

        var cornerDeckPaths: [String: String] = [:]
        for cornerID in profile.cornerDeckPaths.keys.sorted() {
            let originalPath = profile.cornerDeckPaths[cornerID]
            if let resolvedPath = try capturedPath(originalPath) {
                cornerDeckPaths[cornerID] = resolvedPath
            }
        }
        var requiredViewPaths: [String: String] = [:]
        for role in profile.requiredViewPaths.keys.sorted() {
            let originalPath = profile.requiredViewPaths[role]
            if let resolvedPath = try capturedPath(originalPath) {
                requiredViewPaths[role] = resolvedPath
            }
        }
        return PEXProcessProfileReference(
            profileID: profile.profileID,
            pdkID: profile.pdkID,
            source: profile.source,
            requirementID: profile.requirementID,
            pdkRoot: profile.pdkRoot,
            primaryDeckPath: try capturedPath(profile.primaryDeckPath),
            cornerDeckPaths: cornerDeckPaths,
            requiredViewPaths: requiredViewPaths,
            metadata: profile.metadata
        )
    }
}
