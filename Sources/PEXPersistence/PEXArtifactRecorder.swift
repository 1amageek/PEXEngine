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
        let capturedURL = try copy(sourceURL, to: destination)
        return try availableRecord(
            id: "input-\(kind.rawValue)",
            kind: kind,
            stage: .inputValidation,
            cornerID: nil,
            url: capturedURL,
            provenance: PEXArtifactProvenance(sourcePath: sourceURL.path(percentEncoded: false))
        )
    }

    public func captureInlineTechnology(_ technology: TechnologyIR) throws -> PEXArtifactRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(technology)
        let destination = workspace.inputsDirectory.appending(path: "technology.json")
        let capturedURL = try writeImmutableArtifactData(
            data,
            requestedURL: destination,
            failureMessage: "Failed to capture inline technology"
        )
        return try availableRecord(
            id: "input-technologyInput",
            kind: .technologyInput,
            stage: .technologyResolution,
            cornerID: nil,
            url: capturedURL,
            provenance: PEXArtifactProvenance(note: "inline technology")
        )
    }

    public func recordRequest(_ request: PEXRunRequest, inputArtifacts: [PEXArtifactRecord]) throws -> PEXArtifactRecord {
        let captured = PEXCapturedRunRequest(
            topCell: request.topCell,
            layoutFormat: request.layoutFormat,
            sourceNetlistFormat: request.sourceNetlistFormat,
            corners: request.corners,
            processProfile: request.processProfile,
            extractorRunRequest: PEXExtractorRunRequest(runRequest: request),
            backendSelection: request.backendSelection,
            options: request.options,
            inputArtifactIDs: inputArtifacts.map(\.id)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(captured)
        let capturedURL = try writeImmutableArtifactData(
            data,
            requestedURL: workspace.requestURL,
            failureMessage: "Failed to capture request"
        )
        return try availableRecord(
            id: "input-request",
            kind: .request,
            stage: .inputValidation,
            cornerID: nil,
            url: capturedURL,
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
        try unavailableRecord(
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
            let capturedURL: URL
            if generated.url.standardizedFileURL != destination.standardizedFileURL {
                capturedURL = try copy(generated.url, to: destination)
            } else {
                capturedURL = generated.url
            }
            return try availableRecord(
                id: id ?? artifactID(kind: generated.kind, cornerID: generated.cornerID, url: capturedURL),
                kind: generated.kind,
                stage: generated.stage,
                cornerID: generated.cornerID,
                url: capturedURL,
                provenance: generated.provenance
            )
        }
        return try unavailableRecord(
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
        try unavailableRecord(
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

    private func unavailableRecord(
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
        case .spefRoundTrip:
            let cornerID = artifact.cornerID ?? PEXCornerID("uncornered")
            return workspace.spefDirectory.appending(path: name.isEmpty ? "\(cornerID.value).spef" : name)
        case .report:
            return workspace.runDirectory.appending(path: "reports").appending(path: name)
        }
    }

    private func artifactID(kind: PEXArtifactKind, cornerID: PEXCornerID?, url: URL) -> String {
        let corner = cornerID.map { "\($0.value)-" } ?? ""
        let stem = url.deletingPathExtension().lastPathComponent
        return "\(kind.rawValue)-\(corner)\(sanitizedIdentifier(stem))"
    }

    private func copy(_ sourceURL: URL, to destinationURL: URL) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            throw PEXError.persistenceFailed("Artifact source file does not exist: \(sourceURL.path(percentEncoded: false))")
        }
        do {
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
                let sourceData = try Data(contentsOf: sourceURL)
                let destination = try immutableDestinationURL(
                    requestedURL: destinationURL,
                    sourceData: sourceData
                )
                if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                    return destination
                }
                try sourceData.write(to: destination, options: .atomic)
                return destination
            }
            return destinationURL
        } catch let error as PEXError {
            throw error
        } catch {
            throw PEXError.persistenceFailed("Failed to capture artifact \(sourceURL.path(percentEncoded: false))", underlying: error)
        }
    }

    private func immutableDestinationURL(requestedURL: URL, sourceData: Data) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: requestedURL.path(percentEncoded: false)) else {
            return requestedURL
        }
        try ensureExistingFileTargetIsInsideRunDirectory(requestedURL)
        let requestedData = try Data(contentsOf: requestedURL)
        if Self.sha256(data: requestedData) == Self.sha256(data: sourceData) {
            return requestedURL
        }

        let hashPrefix = String(Self.sha256(data: sourceData).prefix(12))
        let directory = requestedURL.deletingLastPathComponent()
        let extensionValue = requestedURL.pathExtension
        let stem = requestedURL.deletingPathExtension().lastPathComponent
        var candidate = directory.appending(path: "\(stem)-\(hashPrefix)")
        if !extensionValue.isEmpty {
            candidate = candidate.appendingPathExtension(extensionValue)
        }
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
            try ensureExistingFileTargetIsInsideRunDirectory(candidate)
            let candidateData = try Data(contentsOf: candidate)
            if Self.sha256(data: candidateData) == Self.sha256(data: sourceData) {
                return candidate
            }
            var next = directory.appending(path: "\(stem)-\(hashPrefix)-\(suffix)")
            if !extensionValue.isEmpty {
                next = next.appendingPathExtension(extensionValue)
            }
            candidate = next
            suffix += 1
        }
        return candidate
    }

    private func writeImmutableArtifactData(
        _ data: Data,
        requestedURL: URL,
        failureMessage: String
    ) throws -> URL {
        do {
            try FileManager.default.createDirectory(
                at: requestedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let destination = try immutableDestinationURL(requestedURL: requestedURL, sourceData: data)
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                return destination
            }
            try data.write(to: destination, options: .atomic)
            return destination
        } catch let error as PEXError {
            throw error
        } catch {
            throw PEXError.persistenceFailed(failureMessage, underlying: error)
        }
    }

    private func relativePath(for url: URL) throws -> PEXArtifactPath {
        let rawRunPath = workspace.runDirectory.path(percentEncoded: false)
        let rawArtifactPath = url.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: rawArtifactPath) {
            if isRawPathInsideRunDirectory(rawArtifactPath, rawRunPath: rawRunPath),
               !pathContainsSymlinkComponent(rawArtifactPath: rawArtifactPath, rawRunPath: rawRunPath)
            {
                let relative = rawArtifactPath == rawRunPath ? "." : String(rawArtifactPath.dropFirst(rawRunPath.count + 1))
                return try PEXArtifactPath(relative)
            }
            return try resolvedRelativePath(for: url, rawArtifactPath: rawArtifactPath)
        }
        if isRawPathInsideRunDirectory(rawArtifactPath, rawRunPath: rawRunPath) {
            let relative = rawArtifactPath == rawRunPath ? "." : String(rawArtifactPath.dropFirst(rawRunPath.count + 1))
            return try PEXArtifactPath(relative)
        }

        return try resolvedRelativePath(for: url, rawArtifactPath: rawArtifactPath)
    }

    private func resolvedRelativePath(for url: URL, rawArtifactPath: String) throws -> PEXArtifactPath {
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
        if FileManager.default.fileExists(atPath: rawArtifactPath) {
            if isRawPathInsideRunDirectory(rawArtifactPath, rawRunPath: rawRunPath),
               !pathContainsSymlinkComponent(rawArtifactPath: rawArtifactPath, rawRunPath: rawRunPath)
            {
                return true
            }
            let runPath = normalizedPath(workspace.runDirectory)
            let artifactPath = normalizedPath(url)
            return artifactPath == runPath || artifactPath.hasPrefix(runPath + "/")
        }
        if isRawPathInsideRunDirectory(rawArtifactPath, rawRunPath: rawRunPath) {
            return true
        }
        let runPath = normalizedPath(workspace.runDirectory)
        let artifactPath = normalizedPath(url)
        return artifactPath == runPath || artifactPath.hasPrefix(runPath + "/")
    }

    private func ensureExistingFileTargetIsInsideRunDirectory(_ url: URL) throws {
        let rawRunPath = workspace.runDirectory.path(percentEncoded: false)
        let rawArtifactPath = url.path(percentEncoded: false)
        if isRawPathInsideRunDirectory(rawArtifactPath, rawRunPath: rawRunPath),
           !pathContainsSymlinkComponent(rawArtifactPath: rawArtifactPath, rawRunPath: rawRunPath)
        {
            return
        }
        let runPath = normalizedPath(workspace.runDirectory)
        let artifactPath = normalizedPath(url)
        guard artifactPath == runPath || artifactPath.hasPrefix(runPath + "/") else {
            throw PEXError.persistenceFailed(
                "Artifact destination target escapes the run directory: \(url.path(percentEncoded: false))"
            )
        }
    }

    private func isRawPathInsideRunDirectory(_ rawArtifactPath: String, rawRunPath: String) -> Bool {
        rawArtifactPath == rawRunPath || rawArtifactPath.hasPrefix(rawRunPath + "/")
    }

    private func pathContainsSymlinkComponent(rawArtifactPath: String, rawRunPath: String) -> Bool {
        guard isRawPathInsideRunDirectory(rawArtifactPath, rawRunPath: rawRunPath), rawArtifactPath != rawRunPath else {
            return false
        }
        let relative = String(rawArtifactPath.dropFirst(rawRunPath.count + 1))
        var currentURL = workspace.runDirectory
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            currentURL = currentURL.appending(path: String(component))
            do {
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: currentURL.path(percentEncoded: false)
                )
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    return true
                }
            } catch {
                continue
            }
        }
        return false
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
    let processProfile: PEXProcessProfileReference?
    let extractorRunRequest: PEXExtractorRunRequest
    let backendSelection: PEXBackendSelection
    let options: PEXRunOptions
    let inputArtifactIDs: [String]
}
