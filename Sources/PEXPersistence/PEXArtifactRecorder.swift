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

    public func captureNativeInputs(_ input: PEXNativeInputReference) throws -> [PEXArtifactRecord] {
        func capture(_ url: URL, kind: PEXArtifactKind, id: String, filename: String,
                     maximumBytes: Int, expected: ArtifactID? = nil) throws -> PEXArtifactRecord {
            let data = try PEXBoundedInputReader().read(url, maximumBytes: maximumBytes)
            guard !data.isEmpty else { throw PEXError.invalidInput("Native input must not be empty: \(url.path)") }
            if let expected {
                guard UInt64(data.count) == expected.byteCount,
                      Self.sha256(data: data) == expected.digest.hexadecimalValue else {
                    throw PEXError.persistenceFailed("Calibration content identity mismatch: \(id)")
                }
            }
            let destination = workspace.inputsDirectory.appending(path: "native").appending(path: filename)
            let captured = try writeImmutableArtifactData(data, requestedURL: destination,
                failureMessage: "Failed to capture native input")
            let record = try availableRecord(id: id, kind: kind, stage: .inputValidation, cornerID: nil,
                url: captured, provenance: PEXArtifactProvenance(sourcePath: url.path), maximumBytes: maximumBytes)
            if let expected, record.reference?.id != expected {
                throw PEXError.persistenceFailed("Saved calibration identity mismatch: \(id)")
            }
            return record
        }
        var records = [try capture(input.configurationURL, kind: .nativeConfigurationInput,
            id: "input-native-configuration", filename: "configuration.json", maximumBytes: input.maximumConfigurationBytes)]
        for source in input.calibrations.sorted(by: { $0.recordID < $1.recordID }) {
            records.append(try capture(source.url, kind: .calibrationInput, id: source.recordID,
                filename: "\(source.recordID).bin", maximumBytes: Int(source.artifactID.byteCount), expected: source.artifactID))
        }
        return records
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
        cornerID: PEXCornerID,
        producer: ProducerIdentity? = nil
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
            provenance: PEXArtifactProvenance(note: "Source-netlist to extracted-pin connectivity comparison"),
            producer: producer
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
        let capturedProfile = try request.processProfile.map { profile in
            try profile.mapInputPaths { path in
                try capturedInputURL(
                    kind: .processProfileDeckInput,
                    sourcePath: path,
                    inputArtifacts: inputArtifacts
                ).path(percentEncoded: false)
            }
        }
        return PEXRunRequest(
            layoutURL: try capturedInputURL(kind: .layoutInput, inputArtifacts: inputArtifacts),
            layoutFormat: request.layoutFormat,
            sourceNetlistURL: try capturedInputURL(kind: .netlistInput, inputArtifacts: inputArtifacts),
            sourceNetlistFormat: request.sourceNetlistFormat,
            topCell: request.topCell,
            corners: request.corners,
            technology: capturedTechnology,
            technologyByCorner: capturedTechnologyByCorner,
            nativeInput: try request.nativeInput.map { input in
                try CapturedPEXNativeInput.resolve(input, records: inputArtifacts) { record in
                    try capturedInputURL(kind: record.matches(kind: .calibrationInput) ? .calibrationInput : .nativeConfigurationInput,
                        artifactID: record.id.rawValue, inputArtifacts: inputArtifacts,
                        maximumBytes: record.matches(kind: .calibrationInput) ? input.maximumCalibrationBytes : input.maximumConfigurationBytes)
                }
            },
            processProfile: capturedProfile,
            backendSelection: request.backendSelection,
            options: request.options,
            workingDirectory: request.workingDirectory,
            executionInputArtifacts: request.executionInputArtifacts
        )
    }

    public func recordRequest(_ request: PEXRunRequest, inputArtifacts: [PEXArtifactRecord]) throws -> PEXArtifactRecord {
        try captureRunRequest(request, inputArtifacts: inputArtifacts).artifact
    }

    /// Verifies captured files once and returns the exact request whose metadata was recorded.
    public func captureRunRequest(_ request: PEXRunRequest, inputArtifacts: [PEXArtifactRecord]) throws
        -> (request: PEXRunRequest, artifact: PEXArtifactRecord) {
        let capturedRequest = try capturedRequest(request, inputArtifacts: inputArtifacts)
        let captured = PEXCapturedRunRequest(
            topCell: request.topCell,
            layoutFormat: request.layoutFormat,
            sourceNetlistFormat: request.sourceNetlistFormat,
            corners: request.corners,
            technology: capturedRequest.technology,
            technologyByCorner: capturedRequest.technologyByCorner,
            nativeInput: capturedRequest.nativeInput,
            processProfile: request.processProfile,
            extractorRunRequest: PEXExtractorRunRequest(runRequest: capturedRequest),
            backendSelection: request.backendSelection,
            options: request.options,
            executionInputArtifacts: request.executionInputArtifacts,
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
        let artifact = try availableRecord(
            id: "input-request",
            kind: .request,
            stage: .inputValidation,
            cornerID: nil,
            url: capturedURL,
            provenance: nil
        )
        return (capturedRequest, artifact)
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
            return .jsonFile(try capturedInputURL(
                kind: .technologyInput,
                artifactID: artifactID,
                inputArtifacts: inputArtifacts
            ))
        }
    }

    private func capturedInputURL(
        kind: PEXArtifactKind,
        artifactID: String? = nil,
        sourcePath: String? = nil,
        inputArtifacts: [PEXArtifactRecord],
        maximumBytes: Int? = nil
    ) throws -> URL {
        let matches = inputArtifacts.filter {
            $0.matches(kind: kind) && $0.availability == .available
                && (artifactID == nil || $0.id.rawValue == artifactID)
                && (sourcePath == nil || $0.provenance?.sourcePath == sourcePath)
        }
        guard matches.count == 1, let record = matches.first, let reference = record.reference else {
            throw PEXError.persistenceFailed("Expected one captured input for \(artifactID ?? sourcePath ?? kind.rawValue)")
        }
        let url = workspace.runDirectory.appending(path: record.relativePath.stringValue)
        try ensureExistingFileTargetIsInsideRunDirectory(url)
        let data: Data
        do {
            if let maximumBytes { data = try PEXBoundedInputReader().read(url, maximumBytes: maximumBytes) }
            else { data = try Data(contentsOf: url) }
        }
        catch { throw PEXError.persistenceFailed("Captured input is unreadable: \(record.id)", underlying: error) }
        guard reference.digest.algorithm == .sha256,
              UInt64(data.count) == reference.byteCount,
              Self.sha256(data: data) == reference.digest.hexadecimalValue else {
            throw PEXError.persistenceFailed("Captured input integrity mismatch: \(record.id)")
        }
        return url
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
                provenance: generated.provenance,
                producer: generated.producer
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
        provenance: PEXArtifactProvenance? = nil,
        producer: ProducerIdentity? = nil
    ) throws -> PEXArtifactRecord {
        let generated = PEXGeneratedArtifact(
            kind: kind,
            stage: stage,
            cornerID: cornerID,
            url: url,
            provenance: provenance,
            producer: producer
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
        provenance: PEXArtifactProvenance?,
        producer: ProducerIdentity? = nil,
        maximumBytes: Int? = nil
    ) throws -> PEXArtifactRecord {
        let data: Data
        do {
            if let maximumBytes { data = try PEXBoundedInputReader().read(url, maximumBytes: maximumBytes) }
            else { data = try Data(contentsOf: url) }
        } catch {
            throw PEXError.persistenceFailed("Failed to read artifact \(url.path(percentEncoded: false))", underlying: error)
        }
        let descriptor = try artifactDescriptor(kind: kind, url: url)
        let relativePath = try artifactRelativePath(for: url)
        let reference = try ArtifactReference(
            digest: try ContentDigest(
                algorithm: .sha256,
                hexadecimalValue: Self.sha256(data: data)
            ),
            byteCount: UInt64(data.count),
            descriptor: descriptor
        )
        let availability = ArtifactAvailability.local(
            artifactID: reference.id,
            rootID: try ArtifactRootID(
                rawValue: "pex-run-\(sanitizedIdentifier(workspace.runID.description))"
            ),
            relativePath: relativePath
        )
        let declaration = PEXArtifactDeclaration(
            id: try PEXArtifactRecordID(rawValue: id),
            descriptor: descriptor,
            relativePath: relativePath
        )
        return try PEXArtifactRecord(
            declaration: declaration,
            payload: .available(try PEXAvailableArtifact(
                reference: reference,
                availability: availability,
                producer: producer
            )),
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
        let descriptor = try artifactDescriptor(kind: kind, url: url)
        let declaration = PEXArtifactDeclaration(
            id: try PEXArtifactRecordID(rawValue: id),
            descriptor: descriptor,
            relativePath: try artifactRelativePath(for: url)
        )
        let payload: PEXArtifactPayload
        switch availability {
        case .available:
            throw PEXError.invalidInput("Unavailable artifact payload cannot be available")
        case .missing:
            payload = .missing
        case .omitted:
            payload = .omitted
        }
        return try PEXArtifactRecord(
            declaration: declaration,
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
        case .layoutInput, .netlistInput, .technologyInput, .nativeConfigurationInput, .calibrationInput, .processProfileDeckInput, .request:
            return workspace.inputsDirectory.appending(path: name)
        case .sourceConnectivityReport:
            let cornerID = artifact.cornerID ?? PEXCornerID("uncornered")
            return workspace.runDirectory
                .appending(path: "reports")
                .appending(path: "source-connectivity")
                .appending(path: name.isEmpty ? "\(cornerID.value).json" : name)
        case .processDriver, .processEvidence, .rawOutput, .log:
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

    private func artifactDescriptor(kind: PEXArtifactKind, url: URL) throws -> ArtifactDescriptor {
        ArtifactDescriptor(
            role: artifactRole(for: kind),
            kind: try ArtifactKind(rawValue: kind.foundationRawValue),
            format: try ArtifactFormat(rawValue: artifactFormatValue(kind: kind, url: url))
        )
    }

    private func artifactRole(for kind: PEXArtifactKind) -> ArtifactRole {
        switch kind {
        case .layoutInput, .netlistInput, .technologyInput, .nativeConfigurationInput, .calibrationInput, .processProfileDeckInput, .request:
            .input
        case .processDriver, .processEvidence, .sourceConnectivityReport, .rawOutput, .log, .parasiticIR,
             .spefRoundTrip, .spiceBackannotation, .report:
            .output
        }
    }

    private func artifactFormatValue(kind: PEXArtifactKind, url: URL) -> String {
        if kind == .calibrationInput { return ArtifactFormat.raw.rawValue }
        return switch url.pathExtension.lowercased() {
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
            case .processDriver, .log: ArtifactFormat.text.rawValue
            default: ArtifactFormat.json.rawValue
            }
        }
    }

    private func artifactRelativePath(for url: URL) throws -> ArtifactRelativePath {
        let rawRunPath = workspace.runDirectory.path(percentEncoded: false)
        let rawArtifactPath = url.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: rawArtifactPath) {
            if isRawPathInsideRunDirectory(rawArtifactPath, rawRunPath: rawRunPath),
               !pathContainsSymlinkComponent(rawArtifactPath: rawArtifactPath, rawRunPath: rawRunPath)
            {
                let relative = rawArtifactPath == rawRunPath ? "." : String(rawArtifactPath.dropFirst(rawRunPath.count + 1))
                return try relativePath(relative)
            }
            return try resolvedRelativePath(for: url, rawArtifactPath: rawArtifactPath)
        }
        if isRawPathInsideRunDirectory(rawArtifactPath, rawRunPath: rawRunPath) {
            let relative = rawArtifactPath == rawRunPath ? "." : String(rawArtifactPath.dropFirst(rawRunPath.count + 1))
            return try relativePath(relative)
        }

        return try resolvedRelativePath(for: url, rawArtifactPath: rawArtifactPath)
    }

    private func resolvedRelativePath(for url: URL, rawArtifactPath: String) throws -> ArtifactRelativePath {
        let runPath = normalizedPath(workspace.runDirectory)
        let artifactPath = normalizedPath(url)
        guard artifactPath == runPath || artifactPath.hasPrefix(runPath + "/") else {
            throw PEXError.persistenceFailed("Artifact is outside the run directory: \(rawArtifactPath)")
        }
        let relative = artifactPath == runPath ? "." : String(artifactPath.dropFirst(runPath.count + 1))
        return try relativePath(relative)
    }

    private func relativePath(_ value: String) throws -> ArtifactRelativePath {
        guard value != "." else {
            throw PEXError.persistenceFailed("An artifact cannot use the run directory as its file path")
        }
        return try ArtifactRelativePath(
            segments: value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        )
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
    let nativeInput: PEXNativeInputReference?
    let processProfile: PEXProcessProfileReference?
    let extractorRunRequest: PEXExtractorRunRequest
    let backendSelection: PEXBackendSelection
    let options: PEXRunOptions
    let executionInputArtifacts: [ArtifactReference]
    let inputArtifactIDs: [String]

    init(
        topCell: String,
        layoutFormat: LayoutFormat,
        sourceNetlistFormat: NetlistFormat,
        corners: [PEXCorner],
        technology: TechnologyInput,
        technologyByCorner: [String: TechnologyInput],
        nativeInput: PEXNativeInputReference?,
        processProfile: PEXProcessProfileReference?,
        extractorRunRequest: PEXExtractorRunRequest,
        backendSelection: PEXBackendSelection,
        options: PEXRunOptions,
        executionInputArtifacts: [ArtifactReference],
        inputArtifactIDs: [String]
    ) {
        self.topCell = topCell
        self.layoutFormat = layoutFormat
        self.sourceNetlistFormat = sourceNetlistFormat
        self.corners = corners
        self.technology = technology
        self.technologyByCorner = technologyByCorner
        self.nativeInput = nativeInput
        self.processProfile = processProfile
        self.extractorRunRequest = extractorRunRequest
        self.backendSelection = backendSelection
        self.options = options
        self.executionInputArtifacts = executionInputArtifacts
        self.inputArtifactIDs = inputArtifactIDs
    }

    private enum CodingKeys: String, CodingKey {
        case topCell
        case layoutFormat
        case sourceNetlistFormat
        case corners
        case technology
        case technologyByCorner
        case nativeInput
        case processProfile
        case extractorRunRequest
        case backendSelection
        case options
        case executionInputArtifacts
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
        self.nativeInput = try container.decodeIfPresent(PEXNativeInputReference.self, forKey: .nativeInput)
        self.processProfile = try container.decodeIfPresent(
            PEXProcessProfileReference.self,
            forKey: .processProfile
        )
        self.extractorRunRequest = try container.decode(PEXExtractorRunRequest.self, forKey: .extractorRunRequest)
        self.backendSelection = try container.decode(PEXBackendSelection.self, forKey: .backendSelection)
        self.options = try container.decode(PEXRunOptions.self, forKey: .options)
        self.executionInputArtifacts = try container.decode(
            [ArtifactReference].self,
            forKey: .executionInputArtifacts
        )
        self.inputArtifactIDs = try container.decode([String].self, forKey: .inputArtifactIDs)
    }
}
