import Foundation
import PEXCore

public struct PEXArtifactStore: Sendable {
    public let workspace: PEXRunWorkspace
    private let serializer: PEXIRSerializer

    public init(workspace: PEXRunWorkspace) {
        self.workspace = workspace
        self.serializer = PEXIRSerializer()
    }

    public func saveManifest(_ manifest: PEXManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(manifest)
        } catch {
            throw PEXError.persistenceFailed("Failed to encode manifest", underlying: error)
        }
        do {
            try data.write(to: workspace.manifestURL)
        } catch {
            throw PEXError.persistenceFailed("Failed to write manifest to \(workspace.manifestURL.path(percentEncoded: false))", underlying: error)
        }
    }

    public func loadManifest() throws -> PEXManifest {
        let data: Data
        do {
            data = try Data(contentsOf: workspace.manifestURL)
        } catch {
            throw PEXError.persistenceFailed("Failed to read manifest from \(workspace.manifestURL.path(percentEncoded: false))", underlying: error)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(PEXManifest.self, from: data)
        } catch {
            throw PEXError.persistenceFailed("Failed to decode manifest", underlying: error)
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
        let url = workspace.cornerIRURL(cornerID)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PEXError.persistenceFailed("Failed to read IR for corner \(cornerID)", underlying: error)
        }
        return try serializer.decode(from: data)
    }

    public func saveReport(_ report: String) throws {
        let data = Data(report.utf8)
        do {
            try data.write(to: workspace.reportURL)
        } catch {
            throw PEXError.persistenceFailed("Failed to write report", underlying: error)
        }
    }

    public func loadResult(cornerIDs: [PEXCornerID], manifest: PEXManifest? = nil) throws -> PEXRunResult {
        let manifest = try manifest ?? loadManifest()

        var cornerResults: [PEXCornerResult] = []
        for cornerID in cornerIDs {
            let ir = try loadIR(for: cornerID)
            let manifestCorner = manifest.corners.first { $0.cornerID == cornerID }
            let status = manifestCorner?.status ?? .success
            cornerResults.append(PEXCornerResult(
                cornerID: cornerID,
                status: status,
                ir: ir,
                rawOutputURLs: [],
                logURL: workspace.cornerLogURL(cornerID),
                warnings: [],
                metrics: PEXCornerMetrics(
                    durationSeconds: 0,
                    netCount: ir.nets.count,
                    elementCount: ir.elements.count
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
            warnings: manifest.warnings.map { PEXWarning(stage: .reporting, message: $0) },
            artifacts: buildArtifactIndex(corners: cornerIDs),
            metrics: PEXRunMetrics(
                totalDurationSeconds: manifest.finishedAt.timeIntervalSince(manifest.startedAt),
                cornerCount: cornerIDs.count,
                successCount: successCount,
                failureCount: failureCount
            )
        )
    }

    public func buildArtifactIndex() -> PEXArtifactIndex {
        // Build from workspace paths - actual file existence is not checked here
        let cornerArtifacts: [PEXCornerID: PEXArtifactIndex.CornerArtifacts] = [:]

        // We don't know corners at this point, so return what we have
        return PEXArtifactIndex(
            manifestURL: workspace.manifestURL,
            requestURL: workspace.requestURL,
            cornerArtifacts: cornerArtifacts,
            reportURL: workspace.reportURL
        )
    }

    public func buildArtifactIndex(corners: [PEXCornerID]) -> PEXArtifactIndex {
        var cornerArtifacts: [PEXCornerID: PEXArtifactIndex.CornerArtifacts] = [:]
        for corner in corners {
            let logURL = workspace.cornerLogURL(corner)
            let logExists = FileManager.default.fileExists(atPath: logURL.path(percentEncoded: false))
            cornerArtifacts[corner] = PEXArtifactIndex.CornerArtifacts(
                rawDirectory: workspace.cornerRawDirectory(corner),
                irURL: workspace.cornerIRURL(corner),
                logURL: logExists ? logURL : nil
            )
        }
        return PEXArtifactIndex(
            manifestURL: workspace.manifestURL,
            requestURL: workspace.requestURL,
            cornerArtifacts: cornerArtifacts,
            reportURL: workspace.reportURL
        )
    }
}
