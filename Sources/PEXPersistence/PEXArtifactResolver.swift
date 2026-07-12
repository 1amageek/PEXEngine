import Foundation
import CryptoKit
import PEXCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct PEXArtifactResolver: Sendable {
    private enum ExplicitPathResolution {
        case resolved(String)
        case rejected
    }

    private enum SymbolicLinkResolution {
        case notSymbolicLink
        case destination(String)
        case unreadable
    }

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

    public func validatedURL(for record: PEXArtifactRecord) throws -> URL {
        if pathEscapesRunDirectory(record.relativePath) {
            throw PEXError.persistenceFailed("Artifact path escapes the run directory: \(record.relativePath.value)")
        }

        let artifactURL = url(for: record)
        if artifactTargetEscapesRunDirectory(artifactURL) {
            throw PEXError.persistenceFailed("Artifact target escapes the run directory: \(record.relativePath.value)")
        }
        return artifactURL
    }

    public func loadIR(cornerID: PEXCornerID) throws -> ParasiticIR {
        guard let record = records(kind: .parasiticIR, cornerID: cornerID, status: .available).first else {
            throw PEXError.persistenceFailed("No available ParasiticIR artifact for corner \(cornerID.value)")
        }
        let url = try validatedURL(for: record)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PEXError.persistenceFailed("Failed to read IR artifact \(record.id)", underlying: error)
        }
        let integrityIssues = availableArtifactIssues(for: record, artifactURL: url)
        if !integrityIssues.isEmpty {
            let message = integrityIssues.map(\.message).joined(separator: "; ")
            throw PEXError.persistenceFailed("IR artifact integrity check failed: \(message)")
        }
        return try serializer.decode(from: data)
    }

    public func completenessReport() -> PEXArtifactCompletenessReport {
        let artifactIDSet = Set(manifest.artifacts.map(\.id))
        let issues = duplicateArtifactIDIssues()
            + manifest.artifacts.flatMap(artifactCompletenessIssues(for:))
            + manifest.corners.flatMap { cornerCompletenessIssues(for: $0, artifactIDSet: artifactIDSet) }

        return PEXArtifactCompletenessReport(status: completenessStatus(for: issues), issues: issues)
    }

    private func duplicateArtifactIDIssues() -> [PEXArtifactCompletenessIssue] {
        let artifactIDCounts = Dictionary(grouping: manifest.artifacts, by: \.id).mapValues(\.count)
        return artifactIDCounts
            .filter { $0.value > 1 }
            .keys
            .sorted()
            .map { artifactID in
                PEXArtifactCompletenessIssue(
                    kind: .duplicateArtifactID,
                    artifactID: artifactID,
                    message: "Artifact id is duplicated in manifest"
                )
            }
    }

    private func artifactCompletenessIssues(for record: PEXArtifactRecord) -> [PEXArtifactCompletenessIssue] {
        let artifactURL: URL
        do {
            artifactURL = try validatedURL(for: record)
        } catch {
            return [
                PEXArtifactCompletenessIssue(
                    kind: .pathEscapesRunDirectory,
                    artifactID: record.id,
                    cornerID: record.cornerID,
                    path: record.relativePath,
                    message: "Artifact path escapes the run directory"
                ),
            ]
        }

        guard record.status == .available else {
            return []
        }

        return availableArtifactIssues(for: record, artifactURL: artifactURL)
    }

    private func availableArtifactIssues(
        for record: PEXArtifactRecord,
        artifactURL: URL
    ) -> [PEXArtifactCompletenessIssue] {
        let path = artifactURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            return [
                PEXArtifactCompletenessIssue(
                    kind: .missingArtifact,
                    artifactID: record.id,
                    cornerID: record.cornerID,
                    path: record.relativePath,
                    message: "Artifact file is missing"
                ),
            ]
        }

        guard let expectedHash = record.sha256 else {
            return [
                PEXArtifactCompletenessIssue(
                    kind: .missingHash,
                    artifactID: record.id,
                    cornerID: record.cornerID,
                    path: record.relativePath,
                    message: "Available artifact is missing a sha256 hash"
                ),
            ]
        }

        guard let expectedByteCount = record.byteCount else {
            return [
                PEXArtifactCompletenessIssue(
                    kind: .missingByteCount,
                    artifactID: record.id,
                    cornerID: record.cornerID,
                    path: record.relativePath,
                    message: "Available artifact is missing a byte count"
                ),
            ]
        }

        do {
            return try integrityIssues(
                for: record,
                artifactURL: artifactURL,
                expectedHash: expectedHash,
                expectedByteCount: expectedByteCount
            )
        } catch {
            return [
                PEXArtifactCompletenessIssue(
                    kind: .missingArtifact,
                    artifactID: record.id,
                    cornerID: record.cornerID,
                    path: record.relativePath,
                    message: "Artifact file could not be read"
                ),
            ]
        }
    }

    private func integrityIssues(
        for record: PEXArtifactRecord,
        artifactURL: URL,
        expectedHash: String,
        expectedByteCount: Int
    ) throws -> [PEXArtifactCompletenessIssue] {
        let data = try Data(contentsOf: artifactURL)
        let actualHash = Self.sha256(data: data)
        if actualHash == expectedHash && expectedByteCount == data.count {
            return []
        }
        return [
            PEXArtifactCompletenessIssue(
                kind: .invalidHash,
                artifactID: record.id,
                cornerID: record.cornerID,
                path: record.relativePath,
                message: "Artifact hash or byte count does not match manifest"
            ),
        ]
    }

    private func cornerCompletenessIssues(
        for corner: PEXArtifactCorner,
        artifactIDSet: Set<String>
    ) -> [PEXArtifactCompletenessIssue] {
        artifactGraphIssues(for: corner, artifactIDSet: artifactIDSet)
            + successCornerIssues(for: corner)
            + failedCornerIssues(for: corner)
    }

    private func artifactGraphIssues(
        for corner: PEXArtifactCorner,
        artifactIDSet: Set<String>
    ) -> [PEXArtifactCompletenessIssue] {
        var issues: [PEXArtifactCompletenessIssue] = []
        for artifactID in corner.artifactIDs where !artifactIDSet.contains(artifactID) {
            issues.append(PEXArtifactCompletenessIssue(
                kind: .missingCornerArtifactReference,
                artifactID: artifactID,
                cornerID: corner.cornerID,
                message: "Corner references an artifact id that is not present in manifest artifacts"
            ))
        }
        for record in manifest.artifacts where record.cornerID == corner.cornerID && !corner.artifactIDs.contains(record.id) {
            issues.append(PEXArtifactCompletenessIssue(
                kind: .missingCornerArtifactReference,
                artifactID: record.id,
                cornerID: corner.cornerID,
                path: record.relativePath,
                message: "Corner-scoped artifact is not referenced by the corner artifact graph"
            ))
        }
        return issues
    }

    private func successCornerIssues(for corner: PEXArtifactCorner) -> [PEXArtifactCompletenessIssue] {
        guard corner.status == .success else {
            return []
        }
        let irRecords = records(kind: .parasiticIR, cornerID: corner.cornerID)
        guard !irRecords.contains(where: { $0.status == .available || $0.status == .omitted }) else {
            return []
        }
        return [
            PEXArtifactCompletenessIssue(
                kind: .missingIR,
                cornerID: corner.cornerID,
                message: "Successful corner has no available or intentionally omitted IR artifact"
            ),
        ]
    }

    private func failedCornerIssues(for corner: PEXArtifactCorner) -> [PEXArtifactCompletenessIssue] {
        guard corner.status == .failed else {
            return []
        }
        var issues = failedCornerFailureIssues(for: corner)
        if failedCornerEvidenceCount(cornerID: corner.cornerID) == 0 {
            issues.append(PEXArtifactCompletenessIssue(
                kind: .failedCornerWithoutEvidence,
                cornerID: corner.cornerID,
                message: "Failed corner has no raw or log evidence artifacts"
            ))
        }
        return issues
    }

    private func failedCornerFailureIssues(for corner: PEXArtifactCorner) -> [PEXArtifactCompletenessIssue] {
        guard let failure = corner.failure else {
            return [
                PEXArtifactCompletenessIssue(
                    kind: .missingFailure,
                    cornerID: corner.cornerID,
                    message: "Failed corner has no structured failure record"
                ),
            ]
        }
        return [
            PEXArtifactCompletenessIssue(
                kind: .failedCorner,
                cornerID: corner.cornerID,
                message: "\(failure.stage.rawValue): \(failure.message)"
            ),
        ]
    }

    private func failedCornerEvidenceCount(cornerID: PEXCornerID) -> Int {
        records(kind: .rawOutput, cornerID: cornerID, status: .available).count
            + records(kind: .log, cornerID: cornerID, status: .available).count
    }

    private func completenessStatus(for issues: [PEXArtifactCompletenessIssue]) -> PEXArtifactCompletenessStatus {
        if issues.isEmpty {
            return .complete
        }
        if issues.contains(where: isInvalidCompletenessIssue) {
            return .invalid
        }
        return .incomplete
    }

    private func isInvalidCompletenessIssue(_ issue: PEXArtifactCompletenessIssue) -> Bool {
        switch issue.kind {
        case .invalidHash, .missingHash, .missingByteCount, .pathEscapesRunDirectory,
             .duplicateArtifactID, .missingCornerArtifactReference:
            return true
        case .missingArtifact, .missingIR, .missingFailure, .failedCorner, .failedCornerWithoutEvidence:
            return false
        }
    }

    public static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func pathEscapesRunDirectory(_ path: PEXArtifactPath) -> Bool {
        path.value.hasPrefix("/") || path.value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private func artifactTargetEscapesRunDirectory(_ artifactURL: URL) -> Bool {
        let runPath = normalizedPath(runDirectory)
        switch explicitlyResolvedPath(for: artifactURL) {
        case .resolved(let artifactPath):
            return !contains(artifactPath, in: runPath)
        case .rejected:
            return true
        }
    }

    private func explicitlyResolvedPath(for url: URL) -> ExplicitPathResolution {
        let standardizedURL = url.standardizedFileURL
        let components = standardizedURL.pathComponents
        guard !components.isEmpty else {
            return .resolved(normalizedDirectoryPath(standardizedURL.path(percentEncoded: false)))
        }

        var currentURL = components[0] == "/"
            ? URL(filePath: "/", directoryHint: .isDirectory)
            : URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)

        for component in components.dropFirst(components[0] == "/" ? 1 : 0) {
            let candidateURL = currentURL.appending(path: component)
            switch symbolicLinkResolution(at: candidateURL) {
            case let .destination(destination):
                currentURL = resolvedDestinationURL(destination, relativeTo: candidateURL)
            case .notSymbolicLink:
                currentURL = candidateURL
            case .unreadable:
                return .rejected
            }
        }
        return .resolved(normalizedDirectoryPath(currentURL.standardizedFileURL.path(percentEncoded: false)))
    }

    private func symbolicLinkResolution(at url: URL) -> SymbolicLinkResolution {
        let path = url.path(percentEncoded: false)
        var fileStat = stat()
        guard path.withCString({ lstat($0, &fileStat) }) == 0 else {
            return .notSymbolicLink
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFLNK else {
            return .notSymbolicLink
        }

        var capacity = Int(PATH_MAX)
        while capacity <= 1_048_576 {
            var buffer = [CChar](repeating: 0, count: capacity + 1)
            let length = path.withCString { pathPointer in
                buffer.withUnsafeMutableBufferPointer { bufferPointer in
                    readlink(pathPointer, bufferPointer.baseAddress, capacity)
                }
            }
            guard length >= 0 else {
                return .unreadable
            }
            guard length < capacity else {
                capacity *= 2
                continue
            }
            let bytes = buffer.prefix(length).map { UInt8(bitPattern: $0) }
            return .destination(String(decoding: bytes, as: UTF8.self))
        }
        return .unreadable
    }

    private func resolvedDestinationURL(_ destination: String, relativeTo symlinkURL: URL) -> URL {
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(filePath: destination)
        } else {
            destinationURL = symlinkURL
                .deletingLastPathComponent()
                .appending(path: destination)
        }
        return destinationURL.standardizedFileURL
    }

    private func contains(_ filePath: String, in rootPath: String) -> Bool {
        filePath == rootPath || filePath.hasPrefix(rootPath + "/")
    }

    private func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return normalizedDirectoryPath(path)
    }

    private func normalizedDirectoryPath(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}
