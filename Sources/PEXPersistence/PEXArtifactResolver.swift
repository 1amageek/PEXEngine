import Foundation
import CryptoKit
import PEXCore

public struct PEXArtifactResolver: Sendable {
    public let manifestURL: URL
    public let runDirectory: URL
    public let manifest: PEXArtifactManifest
    private let serializer: PEXIRSerializer

    public init(manifestURL: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw PEXError.persistenceFailed("Failed to read artifact manifest from \(manifestURL.path(percentEncoded: false))", underlying: error)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let manifest = try decoder.decode(PEXArtifactManifest.self, from: data)
            guard manifest.version == PEXArtifactManifest.currentVersion else {
                throw PEXError.persistenceFailed("Unsupported PEX artifact manifest version \(manifest.version)")
            }
            self.init(
                manifestURL: manifestURL,
                runDirectory: manifestURL.deletingLastPathComponent(),
                manifest: manifest
            )
        } catch let error as PEXError {
            throw error
        } catch {
            throw PEXError.persistenceFailed("Failed to decode artifact manifest", underlying: error)
        }
    }

    public init(workspace: PEXRunWorkspace) throws {
        try self.init(manifestURL: workspace.manifestURL)
    }

    public init(workspace: PEXRunWorkspace, manifest: PEXArtifactManifest) throws {
        self.init(manifestURL: workspace.manifestURL, runDirectory: workspace.runDirectory, manifest: manifest)
    }

    public init(manifestURL: URL, runDirectory: URL, manifest: PEXArtifactManifest) {
        self.manifestURL = manifestURL
        self.runDirectory = runDirectory
        self.manifest = manifest
        self.serializer = PEXIRSerializer()
    }

    public func records(
        kind: PEXArtifactKind,
        cornerID: PEXCornerID? = nil,
        status: PEXArtifactStatus? = nil
    ) -> [PEXArtifactRecord] {
        manifest.artifacts.filter { record in
            record.kind == kind
                && (cornerID == nil || record.cornerID == cornerID)
                && (status == nil || record.status == status)
        }
    }

    public func url(for record: PEXArtifactRecord) -> URL {
        runDirectory.appending(path: record.relativePath.value)
    }

    public func loadIR(cornerID: PEXCornerID) throws -> ParasiticIR {
        guard let record = records(kind: .parasiticIR, cornerID: cornerID, status: .available).first else {
            throw PEXError.persistenceFailed("No available ParasiticIR artifact for corner \(cornerID.value)")
        }
        let url = url(for: record)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PEXError.persistenceFailed("Failed to read IR artifact \(record.id)", underlying: error)
        }
        return try serializer.decode(from: data)
    }

    public func completenessReport() -> PEXArtifactCompletenessReport {
        var issues: [PEXArtifactCompletenessIssue] = []

        for record in manifest.artifacts {
            let artifactURL = url(for: record)
            if pathEscapesRunDirectory(record.relativePath) {
                issues.append(PEXArtifactCompletenessIssue(
                    kind: .pathEscapesRunDirectory,
                    artifactID: record.id,
                    cornerID: record.cornerID,
                    path: record.relativePath,
                    message: "Artifact path escapes the run directory"
                ))
                continue
            }

            guard record.status == .available else {
                continue
            }

            let path = artifactURL.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: path) else {
                issues.append(PEXArtifactCompletenessIssue(
                    kind: .missingArtifact,
                    artifactID: record.id,
                    cornerID: record.cornerID,
                    path: record.relativePath,
                    message: "Artifact file is missing"
                ))
                continue
            }

            guard let expectedHash = record.sha256 else {
                issues.append(PEXArtifactCompletenessIssue(
                    kind: .missingHash,
                    artifactID: record.id,
                    cornerID: record.cornerID,
                    path: record.relativePath,
                    message: "Available artifact is missing a sha256 hash"
                ))
                continue
            }

            do {
                let data = try Data(contentsOf: artifactURL)
                let actualHash = Self.sha256(data: data)
                if actualHash != expectedHash || record.byteCount != data.count {
                    issues.append(PEXArtifactCompletenessIssue(
                        kind: .invalidHash,
                        artifactID: record.id,
                        cornerID: record.cornerID,
                        path: record.relativePath,
                        message: "Artifact hash or byte count does not match manifest"
                    ))
                }
            } catch {
                issues.append(PEXArtifactCompletenessIssue(
                    kind: .missingArtifact,
                    artifactID: record.id,
                    cornerID: record.cornerID,
                    path: record.relativePath,
                    message: "Artifact file could not be read"
                ))
            }
        }

        for corner in manifest.corners {
            let irRecords = records(kind: .parasiticIR, cornerID: corner.cornerID)
            if corner.status == .success && irRecords.allSatisfy({ $0.status != .available && $0.status != .omitted }) {
                issues.append(PEXArtifactCompletenessIssue(
                    kind: .missingIR,
                    cornerID: corner.cornerID,
                    message: "Successful corner has no available or intentionally omitted IR artifact"
                ))
            }

            if corner.status == .failed {
                if let failure = corner.failure {
                    issues.append(PEXArtifactCompletenessIssue(
                        kind: .failedCorner,
                        cornerID: corner.cornerID,
                        message: "\(failure.stage.rawValue): \(failure.message)"
                    ))
                }
                let evidenceCount = records(kind: .rawOutput, cornerID: corner.cornerID, status: .available).count
                    + records(kind: .log, cornerID: corner.cornerID, status: .available).count
                if evidenceCount == 0 {
                    issues.append(PEXArtifactCompletenessIssue(
                        kind: .failedCornerWithoutEvidence,
                        cornerID: corner.cornerID,
                        message: "Failed corner has no raw or log evidence artifacts"
                    ))
                }
            }
        }

        let status: PEXArtifactCompletenessStatus
        if issues.isEmpty {
            status = .complete
        } else if issues.contains(where: { $0.kind == .invalidHash || $0.kind == .pathEscapesRunDirectory }) {
            status = .invalid
        } else {
            status = .incomplete
        }

        return PEXArtifactCompletenessReport(status: status, issues: issues)
    }

    public static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func pathEscapesRunDirectory(_ path: PEXArtifactPath) -> Bool {
        path.value.hasPrefix("/") || path.value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}
