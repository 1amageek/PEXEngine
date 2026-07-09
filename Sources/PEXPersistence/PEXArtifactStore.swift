import Foundation
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

    public func loadResult(manifest: PEXArtifactManifest? = nil) throws -> PEXRunResult {
        let manifest = try manifest ?? loadManifest()
        let resolver = try PEXArtifactResolver(workspace: workspace, manifest: manifest)
        var cornerResults: [PEXCornerResult] = []

        for corner in manifest.corners {
            let rawOutputURLs = try resolver.records(kind: .rawOutput, cornerID: corner.cornerID, status: .available)
                .map { try resolver.validatedURL(for: $0) }
            let logURL: URL?
            if let logRecord = resolver.records(kind: .log, cornerID: corner.cornerID, status: .available).first {
                logURL = try resolver.validatedURL(for: logRecord)
            } else {
                logURL = nil
            }
            let ir: ParasiticIR?
            if resolver.records(kind: .parasiticIR, cornerID: corner.cornerID, status: .available).isEmpty {
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

        return PEXRunResult(
            runID: manifest.runID,
            requestHash: manifest.requestHash,
            status: manifest.status,
            startedAt: manifest.startedAt,
            finishedAt: manifest.finishedAt,
            cornerResults: cornerResults,
            warnings: manifest.warnings,
            artifacts: manifest,
            manifestURL: workspace.manifestURL,
            metrics: PEXRunMetrics(
                totalDurationSeconds: manifest.finishedAt.timeIntervalSince(manifest.startedAt),
                cornerCount: manifest.corners.count,
                successCount: successCount,
                failureCount: failureCount
            ),
            extractorRun: manifest.extractorRun
        )
    }
}
