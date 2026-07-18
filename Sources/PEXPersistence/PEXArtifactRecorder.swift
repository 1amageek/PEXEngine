import Foundation
import CryptoKit
import CircuiteFoundation
import PEXCore

public struct PEXArtifactRecorder: Sendable {
    public let workspace: PEXRunWorkspace

    public init(workspace: PEXRunWorkspace) {
        self.workspace = workspace
    }

    public func captureInput(
        url sourceURL: URL,
        kind: PEXArtifactKind,
        id: String? = nil,
        destinationFilename: String? = nil
    ) throws -> PEXArtifactRecord {
        let destination = workspace.inputsDirectory.appending(
            path: sanitizedFileName(destinationFilename ?? sourceURL.lastPathComponent)
        )
        let capturedURL = try copy(sourceURL, to: destination)
        return try availableRecord(
            id: id ?? "input-\(kind.rawValue)",
            kind: kind,
            stage: .inputValidation,
            cornerID: nil,
            url: capturedURL,
            provenance: PEXArtifactProvenance(sourcePath: sourceURL.path(percentEncoded: false))
        )
    }

    public func captureProcessProfileDeck(
        path: String,
        identifier: String
    ) throws -> PEXArtifactRecord {
        let sourceURL = URL(filePath: path)
        let directory = workspace.inputsDirectory.appending(path: "process-profile-decks")
        let filename = "\(sanitizedIdentifier(identifier))-\(sanitizedFileName(sourceURL.lastPathComponent))"
        let destination = directory.appending(path: filename)
        let capturedURL = try copy(sourceURL, to: destination)
        return try availableRecord(
            id: "input-process-profile-deck-\(sanitizedIdentifier(identifier))",
            kind: .processProfileDeckInput,
            stage: .inputValidation,
            cornerID: nil,
            url: capturedURL,
            provenance: PEXArtifactProvenance(sourcePath: sourceURL.path(percentEncoded: false))
        )
    }

    public func captureInlineTechnology(
        _ technology: TechnologyIR,
        id: String = "input-technologyInput",
        destinationFilename: String = "technology.json"
    ) throws -> PEXArtifactRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(technology)
        let destination = workspace.inputsDirectory.appending(path: sanitizedFileName(destinationFilename))
        let capturedURL = try writeImmutableArtifactData(
            data,
            requestedURL: destination,
            failureMessage: "Failed to capture inline technology"
        )
        return try availableRecord(
            id: id,
            kind: .technologyInput,
            stage: .technologyResolution,
            cornerID: nil,
            url: capturedURL,
            provenance: PEXArtifactProvenance(note: "inline technology")
        )
    }

    public func recordSourceConnectivityReport(
        _ report: PEXSourceConnectivityReport,
        cornerID: PEXCornerID
    ) throws -> PEXArtifactRecord {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(report)
        } catch {
            throw PEXError.persistenceFailed("Failed to encode source connectivity report", underlying: error)
        }
        let destination = workspace.cornerSourceConnectivityURL(cornerID)
        let capturedURL = try writeImmutableArtifactData(
            data,
            requestedURL: destination,
            failureMessage: "Failed to capture source connectivity report"
        )
        return try availableRecord(
            id: "source-connectivity-\(cornerID.value)",
            kind: .sourceConnectivityReport,
            stage: .irValidation,
            cornerID: cornerID,
            url: capturedURL,
            provenance: PEXArtifactProvenance(note: "Source-netlist to extracted-pin connectivity comparison")
        )
    }

    public func capturedRequest(
        _ request: PEXRunRequest,
        inputArtifacts: [PEXArtifactRecord]
    ) throws -> PEXRunRequest {
        let capturedTechnology = try capturedTechnologyInput(
            request.technology,
            artifactID: "input-technologyInput",
            inputArtifacts: inputArtifacts
        )
        var capturedTechnologyByCorner: [String: TechnologyInput] = [:]
        for cornerID in request.technologyByCorner.keys.sorted() {
            guard let technologyInput = request.technologyByCorner[cornerID] else {
                throw PEXError.internalInvariantViolation(
                    "Per-corner technology input is missing for corner '\(cornerID)'"
                )
            }
            capturedTechnologyByCorner[cornerID] = try capturedTechnologyInput(
                technologyInput,
                artifactID: "input-technologyInput-\(sanitizedIdentifier(cornerID))",
                inputArtifacts: inputArtifacts
            )
        }
        return PEXRunRequest(
            layoutURL: request.layoutURL,
            layoutFormat: request.layoutFormat,
            sourceNetlistURL: request.sourceNetlistURL,
            sourceNetlistFormat: request.sourceNetlistFormat,
            topCell: request.topCell,
            corners: request.corners,
            technology: capturedTechnology,
            technologyByCorner: capturedTechnologyByCorner,
            processProfile: request.processProfile,
            backendSelection: request.backendSelection,
            options: request.options,
            workingDirectory: request.workingDirectory
        )
    }

    public func recordRequest(_ request: PEXRunRequest, inputArtifacts: [PEXArtifactRecord]) throws -> PEXArtifactRecord {
        let capturedRequest = try capturedRequest(request, inputArtifacts: inputArtifacts)
        let captured = PEXCapturedRunRequest(
            topCell: request.topCell,
            layoutFormat: request.layoutFormat,
            sourceNetlistFormat: request.sourceNetlistFormat,
            corners: request.corners,
            technology: capturedRequest.technology,
            technologyByCorner: capturedRequest.technologyByCorner,
            processProfile: request.processProfile,
            extractorRunRequest: PEXExtractorRunRequest(runRequest: capturedRequest),
            backendSelection: request.backendSelection,
            options: request.options,
            inputArtifactIDs: inputArtifacts.map { $0.id.rawValue }
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

    private func capturedTechnologyInput(
        _ input: TechnologyInput,
        artifactID: String,
        inputArtifacts: [PEXArtifactRecord]
    ) throws -> TechnologyInput {
        switch input {
        case .inline(let technology):
            return .inline(technology)
        case .jsonFile:
            guard let record = inputArtifacts.first(where: {
                $0.id.rawValue == artifactID && $0.availability == .available
            }) else {
                throw PEXError.persistenceFailed(
                    "Captured technology artifact '\(artifactID)' is missing"
                )
            }
            let path = workspace.runDirectory
                .appending(path: record.locator.location.value)
                .path(percentEncoded: false)
            return .jsonFile(URL(filePath: path))
        }
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
            availability: .missing,
            provenance: PEXArtifactProvenance(note: note)
        )
    }

    public func recordGeneratedArtifact(
        _ generated: PEXGeneratedArtifact,
        id: String? = nil
    ) throws -> PEXArtifactRecord {
        let destination = destinationURL(for: generated)
        if generated.availability == .available {
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
            availability: generated.availability,
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
            availability: .omitted,
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
        let locator = try artifactLocator(kind: kind, url: url)
        let reference = ArtifactReference(
            id: try ArtifactID(rawValue: id),
            locator: locator,
            digest: try ContentDigest(
                algorithm: .sha256,
                hexadecimalValue: Self.sha256(data: data)
            ),
            byteCount: UInt64(data.count)
        )
        return PEXArtifactRecord(
            payload: .available(reference),
            stage: stage,
            cornerID: cornerID,
            provenance: provenance
        )
    }

    private func unavailableRecord(
        id: String,
        kind: PEXArtifactKind,
        stage: PEXStage,
        cornerID: PEXCornerID?,
        url: URL,
        availability: PEXArtifactAvailability,
        provenance: PEXArtifactProvenance?
    ) throws -> PEXArtifactRecord {
        let declaration = PEXArtifactDeclaration(
            id: try ArtifactID(rawValue: id),
            locator: try artifactLocator(kind: kind, url: url)
        )
        let payload: PEXArtifactPayload
        switch availability {
        case .available:
            throw PEXError.invalidInput("Unavailable artifact payload cannot be available")
        case .missing:
            payload = .missing(declaration)
        case .omitted:
            payload = .omitted(declaration)
        }
        return PEXArtifactRecord(
            payload: payload,
            stage: stage,
            cornerID: cornerID,
            provenance: provenance
        )
    }

    private func destinationURL(for artifact: PEXGeneratedArtifact) -> URL {
        if isInsideRunDirectory(artifact.url) {
            return artifact.url
        }
        let name = sanitizedFileName(artifact.url.lastPathComponent)
        switch artifact.kind {
        case .layoutInput, .netlistInput, .technologyInput, .processProfileDeckInput, .request:
            return workspace.inputsDirectory.appending(path: name)
        case .sourceConnectivityReport:
            let cornerID = artifact.cornerID ?? PEXCornerID("uncornered")
            return workspace.runDirectory
                .appending(path: "reports")
                .appending(path: "source-connectivity")
                .appending(path: name.isEmpty ? "\(cornerID.value).json" : name)
        case .rawOutput, .log:
            let cornerID = artifact.cornerID ?? PEXCornerID("uncornered")
            return workspace.cornerRawDirectory(cornerID).appending(path: name)
        case .parasiticIR:
            let cornerID = artifact.cornerID ?? PEXCornerID("uncornered")
            return workspace.runDirectory.appending(path: "ir").appending(path: name.isEmpty ? "\(cornerID.value).json" : name)
        case .spefRoundTrip:
            let cornerID = artifact.cornerID ?? PEXCornerID("uncornered")
            return workspace.spefDirectory.appending(path: name.isEmpty ? "\(cornerID.value).spef" : name)
        case .spiceBackannotation:
            let cornerID = artifact.cornerID ?? PEXCornerID("uncornered")
            return workspace.runDirectory.appending(path: "spice").appending(path: name.isEmpty ? "\(cornerID.value).cir" : name)
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

    private func artifactLocator(kind: PEXArtifactKind, url: URL) throws -> ArtifactLocator {
        ArtifactLocator(
            location: try relativeLocation(for: url),
            role: artifactRole(for: kind),
            kind: try ArtifactKind(rawValue: kind.foundationRawValue),
            format: try ArtifactFormat(rawValue: artifactFormatValue(kind: kind, url: url))
        )
    }

    private func artifactRole(for kind: PEXArtifactKind) -> ArtifactRole {
        switch kind {
        case .layoutInput, .netlistInput, .technologyInput, .processProfileDeckInput, .request:
            .input
        case .sourceConnectivityReport, .rawOutput, .log, .parasiticIR,
             .spefRoundTrip, .spiceBackannotation, .report:
            .output
        }
    }

    private func artifactFormatValue(kind: PEXArtifactKind, url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "gds", "gdsii": ArtifactFormat.gdsii.rawValue
        case "oas", "oasis": ArtifactFormat.oasis.rawValue
        case "lef": ArtifactFormat.lef.rawValue
        case "def": ArtifactFormat.def.rawValue
        case "spef": ArtifactFormat.spef.rawValue
        case "dspf": ArtifactFormat.dspf.rawValue
        case "sp", "cir", "spice": ArtifactFormat.spice.rawValue
        case "log", "txt": ArtifactFormat.text.rawValue
        default:
            switch kind {
            case .spefRoundTrip: ArtifactFormat.spef.rawValue
            case .spiceBackannotation, .netlistInput: ArtifactFormat.spice.rawValue
            case .layoutInput: ArtifactFormat.gdsii.rawValue
            case .log: ArtifactFormat.text.rawValue
            default: ArtifactFormat.json.rawValue
            }
        }
    }

    private func relativeLocation(for url: URL) throws -> ArtifactLocation {
        let rawRunPath = workspace.runDirectory.path(percentEncoded: false)
        let rawArtifactPath = url.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: rawArtifactPath) {
            if isRawPathInsideRunDirectory(rawArtifactPath, rawRunPath: rawRunPath),
               !pathContainsSymlinkComponent(rawArtifactPath: rawArtifactPath, rawRunPath: rawRunPath)
            {
                let relative = rawArtifactPath == rawRunPath ? "." : String(rawArtifactPath.dropFirst(rawRunPath.count + 1))
                return try ArtifactLocation(workspaceRelativePath: relative)
            }
            return try resolvedRelativePath(for: url, rawArtifactPath: rawArtifactPath)
        }
        if isRawPathInsideRunDirectory(rawArtifactPath, rawRunPath: rawRunPath) {
            let relative = rawArtifactPath == rawRunPath ? "." : String(rawArtifactPath.dropFirst(rawRunPath.count + 1))
            return try ArtifactLocation(workspaceRelativePath: relative)
        }

        return try resolvedRelativePath(for: url, rawArtifactPath: rawArtifactPath)
    }

    private func resolvedRelativePath(for url: URL, rawArtifactPath: String) throws -> ArtifactLocation {
        let runPath = normalizedPath(workspace.runDirectory)
        let artifactPath = normalizedPath(url)
        guard artifactPath == runPath || artifactPath.hasPrefix(runPath + "/") else {
            throw PEXError.persistenceFailed("Artifact is outside the run directory: \(rawArtifactPath)")
        }
        let relative = artifactPath == runPath ? "." : String(artifactPath.dropFirst(runPath.count + 1))
        return try ArtifactLocation(workspaceRelativePath: relative)
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

struct PEXCapturedRunRequest: Sendable, Codable, Hashable {
    let topCell: String
    let layoutFormat: LayoutFormat
    let sourceNetlistFormat: NetlistFormat
    let corners: [PEXCorner]
    let technology: TechnologyInput
    let technologyByCorner: [String: TechnologyInput]
    let processProfile: PEXProcessProfileReference?
    let extractorRunRequest: PEXExtractorRunRequest
    let backendSelection: PEXBackendSelection
    let options: PEXRunOptions
    let inputArtifactIDs: [String]

    init(
        topCell: String,
        layoutFormat: LayoutFormat,
        sourceNetlistFormat: NetlistFormat,
        corners: [PEXCorner],
        technology: TechnologyInput,
        technologyByCorner: [String: TechnologyInput],
        processProfile: PEXProcessProfileReference?,
        extractorRunRequest: PEXExtractorRunRequest,
        backendSelection: PEXBackendSelection,
        options: PEXRunOptions,
        inputArtifactIDs: [String]
    ) {
        self.topCell = topCell
        self.layoutFormat = layoutFormat
        self.sourceNetlistFormat = sourceNetlistFormat
        self.corners = corners
        self.technology = technology
        self.technologyByCorner = technologyByCorner
        self.processProfile = processProfile
        self.extractorRunRequest = extractorRunRequest
        self.backendSelection = backendSelection
        self.options = options
        self.inputArtifactIDs = inputArtifactIDs
    }

    private enum CodingKeys: String, CodingKey {
        case topCell
        case layoutFormat
        case sourceNetlistFormat
        case corners
        case technology
        case technologyByCorner
        case processProfile
        case extractorRunRequest
        case backendSelection
        case options
        case inputArtifactIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.topCell = try container.decode(String.self, forKey: .topCell)
        self.layoutFormat = try container.decode(LayoutFormat.self, forKey: .layoutFormat)
        self.sourceNetlistFormat = try container.decode(NetlistFormat.self, forKey: .sourceNetlistFormat)
        self.corners = try container.decode([PEXCorner].self, forKey: .corners)
        self.technology = try container.decode(TechnologyInput.self, forKey: .technology)
        self.technologyByCorner = try container.decode(
            [String: TechnologyInput].self,
            forKey: .technologyByCorner
        )
        self.processProfile = try container.decodeIfPresent(
            PEXProcessProfileReference.self,
            forKey: .processProfile
        )
        self.extractorRunRequest = try container.decode(PEXExtractorRunRequest.self, forKey: .extractorRunRequest)
        self.backendSelection = try container.decode(PEXBackendSelection.self, forKey: .backendSelection)
        self.options = try container.decode(PEXRunOptions.self, forKey: .options)
        self.inputArtifactIDs = try container.decode([String].self, forKey: .inputArtifactIDs)
    }
}
