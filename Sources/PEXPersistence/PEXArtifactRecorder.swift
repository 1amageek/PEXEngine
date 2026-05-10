import Foundation
import CryptoKit
import PEXCore

public struct PEXArtifactRecorder: Sendable {
    public let workspace: PEXRunWorkspace

    public init(workspace: PEXRunWorkspace) {
        self.workspace = workspace
    }

    public func captureInput(url sourceURL: URL, kind: PEXArtifactKind) throws -> PEXArtifactRecord {
        let destination = workspace.inputsDirectory.appending(path: sanitizedFileName(sourceURL.lastPathComponent))
        try copy(sourceURL, to: destination)
        return try availableRecord(
            id: "input-\(kind.rawValue)",
            kind: kind,
            stage: .inputValidation,
            cornerID: nil,
            url: destination,
            provenance: PEXArtifactProvenance(sourcePath: sourceURL.path(percentEncoded: false))
        )
    }

    public func captureInlineTechnology(_ technology: TechnologyIR) throws -> PEXArtifactRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(technology)
        let destination = workspace.inputsDirectory.appending(path: "technology.json")
        do {
            try data.write(to: destination)
        } catch {
            throw PEXError.persistenceFailed("Failed to capture inline technology", underlying: error)
        }
        return try availableRecord(
            id: "input-technologyInput",
            kind: .technologyInput,
            stage: .technologyResolution,
            cornerID: nil,
            url: destination,
            provenance: PEXArtifactProvenance(note: "inline technology")
        )
    }

    public func recordRequest(_ request: PEXRunRequest, inputArtifacts: [PEXArtifactRecord]) throws -> PEXArtifactRecord {
        let captured = PEXCapturedRunRequest(
            topCell: request.topCell,
            layoutFormat: request.layoutFormat,
            sourceNetlistFormat: request.sourceNetlistFormat,
            corners: request.corners,
            backendSelection: request.backendSelection,
            options: request.options,
            inputArtifactIDs: inputArtifacts.map(\.id)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(captured)
        do {
            try data.write(to: workspace.requestURL)
        } catch {
            throw PEXError.persistenceFailed("Failed to capture request", underlying: error)
        }
        return try availableRecord(
            id: "input-request",
            kind: .request,
            stage: .inputValidation,
            cornerID: nil,
            url: workspace.requestURL,
            provenance: nil
        )
    }

    public func recordMissingArtifact(
        kind: PEXArtifactKind,
        stage: PEXStage,
        cornerID: PEXCornerID? = nil,
        expectedURL: URL,
        id: String? = nil,
        note: String
    ) throws -> PEXArtifactRecord {
        try placeholderRecord(
            id: id ?? artifactID(kind: kind, cornerID: cornerID, url: expectedURL),
            kind: kind,
            stage: stage,
            cornerID: cornerID,
            url: expectedURL,
            status: .missing,
            provenance: PEXArtifactProvenance(note: note)
        )
    }

    public func recordGeneratedArtifact(
        _ generated: PEXGeneratedArtifact,
        id: String? = nil
    ) throws -> PEXArtifactRecord {
        let destination = destinationURL(for: generated)
        if generated.status == .available {
            if generated.url.standardizedFileURL != destination.standardizedFileURL {
                try copy(generated.url, to: destination)
            }
            return try availableRecord(
                id: id ?? artifactID(kind: generated.kind, cornerID: generated.cornerID, url: destination),
                kind: generated.kind,
                stage: generated.stage,
                cornerID: generated.cornerID,
                url: destination,
                provenance: generated.provenance
            )
        }
        return try placeholderRecord(
            id: id ?? artifactID(kind: generated.kind, cornerID: generated.cornerID, url: destination),
            kind: generated.kind,
            stage: generated.stage,
            cornerID: generated.cornerID,
            url: destination,
            status: generated.status,
            provenance: generated.provenance
        )
    }

    public func recordExistingArtifact(
        url: URL,
        kind: PEXArtifactKind,
        stage: PEXStage,
        cornerID: PEXCornerID? = nil,
        id: String? = nil,
        provenance: PEXArtifactProvenance? = nil
    ) throws -> PEXArtifactRecord {
        let generated = PEXGeneratedArtifact(
            kind: kind,
            stage: stage,
            cornerID: cornerID,
            url: url,
            provenance: provenance
        )
        return try recordGeneratedArtifact(generated, id: id)
    }

    public func recordOmittedArtifact(
        kind: PEXArtifactKind,
        stage: PEXStage,
        cornerID: PEXCornerID,
        expectedURL: URL,
        id: String? = nil,
        note: String
    ) throws -> PEXArtifactRecord {
        try placeholderRecord(
            id: id ?? artifactID(kind: kind, cornerID: cornerID, url: expectedURL),
            kind: kind,
            stage: stage,
            cornerID: cornerID,
            url: expectedURL,
            status: .omitted,
            provenance: PEXArtifactProvenance(note: note)
        )
    }

    private func availableRecord(
        id: String,
        kind: PEXArtifactKind,
        stage: PEXStage,
        cornerID: PEXCornerID?,
        url: URL,
        provenance: PEXArtifactProvenance?
    ) throws -> PEXArtifactRecord {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PEXError.persistenceFailed("Failed to read artifact \(url.path(percentEncoded: false))", underlying: error)
        }
        return PEXArtifactRecord(
            id: id,
            kind: kind,
            stage: stage,
            cornerID: cornerID,
            relativePath: try relativePath(for: url),
            sha256: Self.sha256(data: data),
            byteCount: data.count,
            status: .available,
            provenance: provenance
        )
    }

    private func placeholderRecord(
        id: String,
        kind: PEXArtifactKind,
        stage: PEXStage,
        cornerID: PEXCornerID?,
        url: URL,
        status: PEXArtifactStatus,
        provenance: PEXArtifactProvenance?
    ) throws -> PEXArtifactRecord {
        PEXArtifactRecord(
            id: id,
            kind: kind,
            stage: stage,
            cornerID: cornerID,
            relativePath: try relativePath(for: url),
            status: status,
            provenance: provenance
        )
    }

    private func destinationURL(for artifact: PEXGeneratedArtifact) -> URL {
        if isInsideRunDirectory(artifact.url) {
            return artifact.url
        }
        let name = sanitizedFileName(artifact.url.lastPathComponent)
        switch artifact.kind {
        case .layoutInput, .netlistInput, .technologyInput, .request:
            return workspace.inputsDirectory.appending(path: name)
        case .rawOutput, .log:
            let cornerID = artifact.cornerID ?? PEXCornerID("uncornered")
            return workspace.cornerRawDirectory(cornerID).appending(path: name)
        case .parasiticIR:
            let cornerID = artifact.cornerID ?? PEXCornerID("uncornered")
            return workspace.runDirectory.appending(path: "ir").appending(path: name.isEmpty ? "\(cornerID.value).json" : name)
        case .report:
            return workspace.runDirectory.appending(path: "reports").appending(path: name)
        }
    }

    private func artifactID(kind: PEXArtifactKind, cornerID: PEXCornerID?, url: URL) -> String {
        let corner = cornerID.map { "\($0.value)-" } ?? ""
        let stem = url.deletingPathExtension().lastPathComponent
        return "\(kind.rawValue)-\(corner)\(sanitizedIdentifier(stem))"
    }

    private func copy(_ sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            throw PEXError.persistenceFailed("Artifact source file does not exist: \(sourceURL.path(percentEncoded: false))")
        }
        do {
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
                if fileManager.fileExists(atPath: destinationURL.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
        } catch let error as PEXError {
            throw error
        } catch {
            throw PEXError.persistenceFailed("Failed to capture artifact \(sourceURL.path(percentEncoded: false))", underlying: error)
        }
    }

    private func relativePath(for url: URL) throws -> PEXArtifactPath {
        let rawRunPath = workspace.runDirectory.path(percentEncoded: false)
        let rawArtifactPath = url.path(percentEncoded: false)
        if rawArtifactPath == rawRunPath || rawArtifactPath.hasPrefix(rawRunPath + "/") {
            let relative = rawArtifactPath == rawRunPath ? "." : String(rawArtifactPath.dropFirst(rawRunPath.count + 1))
            return try PEXArtifactPath(relative)
        }

        let runPath = normalizedPath(workspace.runDirectory)
        let artifactPath = normalizedPath(url)
        guard artifactPath == runPath || artifactPath.hasPrefix(runPath + "/") else {
            throw PEXError.persistenceFailed("Artifact is outside the run directory: \(rawArtifactPath)")
        }
        let relative = artifactPath == runPath ? "." : String(artifactPath.dropFirst(runPath.count + 1))
        return try PEXArtifactPath(relative)
    }

    private func isInsideRunDirectory(_ url: URL) -> Bool {
        let rawRunPath = workspace.runDirectory.path(percentEncoded: false)
        let rawArtifactPath = url.path(percentEncoded: false)
        if rawArtifactPath == rawRunPath || rawArtifactPath.hasPrefix(rawRunPath + "/") {
            return true
        }
        let runPath = normalizedPath(workspace.runDirectory)
        let artifactPath = normalizedPath(url)
        return artifactPath == runPath || artifactPath.hasPrefix(runPath + "/")
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    private func sanitizedFileName(_ value: String) -> String {
        let base = value.isEmpty ? "artifact" : value
        return base.map { character in
            character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
                ? character
                : "_"
        }.map(String.init).joined()
    }

    private func sanitizedIdentifier(_ value: String) -> String {
        let base = value.isEmpty ? "artifact" : value
        return base.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "-"
        }.map(String.init).joined()
    }

    private static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct PEXCapturedRunRequest: Sendable, Codable, Hashable {
    let topCell: String
    let layoutFormat: LayoutFormat
    let sourceNetlistFormat: NetlistFormat
    let corners: [PEXCorner]
    let backendSelection: PEXBackendSelection
    let options: PEXRunOptions
    let inputArtifactIDs: [String]
}
