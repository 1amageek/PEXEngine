import Foundation

public struct PEXArtifactPath: Sendable, Codable, Hashable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) throws {
        guard !value.isEmpty else {
            throw PEXError.invalidInput("Artifact path must not be empty")
        }
        guard !value.hasPrefix("/") else {
            throw PEXError.invalidInput("Artifact path must be relative to the run directory")
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw PEXError.invalidInput("Artifact path must not escape the run directory")
        }
        self.value = value
    }

    public init(validated value: String) {
        self.value = value
    }

    public var description: String { value }
}

public enum PEXArtifactKind: String, Sendable, Codable, Hashable, CaseIterable {
    case layoutInput
    case netlistInput
    case technologyInput
    case request
    case rawOutput
    case log
    case parasiticIR
    case spefRoundTrip
    case report
}

public enum PEXArtifactStatus: String, Sendable, Codable, Hashable {
    case available
    case missing
    case omitted
}

public struct PEXArtifactProvenance: Sendable, Codable, Hashable {
    public let sourcePath: String?
    public let note: String?

    public init(sourcePath: String? = nil, note: String? = nil) {
        self.sourcePath = sourcePath
        self.note = note
    }
}

public struct PEXArtifactRecord: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let kind: PEXArtifactKind
    public let stage: PEXStage
    public let cornerID: PEXCornerID?
    public let relativePath: PEXArtifactPath
    public let sha256: String?
    public let byteCount: Int?
    public let createdAt: Date
    public let status: PEXArtifactStatus
    public let provenance: PEXArtifactProvenance?

    public init(
        id: String,
        kind: PEXArtifactKind,
        stage: PEXStage,
        cornerID: PEXCornerID? = nil,
        relativePath: PEXArtifactPath,
        sha256: String? = nil,
        byteCount: Int? = nil,
        createdAt: Date = Date(),
        status: PEXArtifactStatus,
        provenance: PEXArtifactProvenance? = nil
    ) {
        self.id = id
        self.kind = kind
        self.stage = stage
        self.cornerID = cornerID
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.status = status
        self.provenance = provenance
    }
}

public struct PEXArtifactFailure: Sendable, Codable, Hashable {
    public let stage: PEXStage
    public let message: String
    public let suggestedActions: [String]

    public init(stage: PEXStage, message: String, suggestedActions: [String] = []) {
        self.stage = stage
        self.message = message
        self.suggestedActions = suggestedActions
    }
}

public struct PEXArtifactCorner: Sendable, Codable, Hashable {
    public let cornerID: PEXCornerID
    public let status: PEXRunStatus
    public let artifactIDs: [String]
    public let failure: PEXArtifactFailure?

    public init(
        cornerID: PEXCornerID,
        status: PEXRunStatus,
        artifactIDs: [String],
        failure: PEXArtifactFailure? = nil
    ) {
        self.cornerID = cornerID
        self.status = status
        self.artifactIDs = artifactIDs
        self.failure = failure
    }
}

public struct PEXArtifactManifest: Sendable, Codable, Hashable {
    public static let currentVersion = 2

    public let version: Int
    public let runID: PEXRunID
    public let requestHash: PEXRequestHash
    public let backendID: String
    public let status: PEXRunStatus
    public let startedAt: Date
    public let finishedAt: Date
    public let corners: [PEXArtifactCorner]
    public let artifacts: [PEXArtifactRecord]
    public let warnings: [PEXWarning]
    public let extractorRun: PEXExtractorRunResult?

    public init(
        version: Int = PEXArtifactManifest.currentVersion,
        runID: PEXRunID,
        requestHash: PEXRequestHash,
        backendID: String,
        status: PEXRunStatus,
        startedAt: Date,
        finishedAt: Date,
        corners: [PEXArtifactCorner],
        artifacts: [PEXArtifactRecord],
        warnings: [PEXWarning],
        extractorRun: PEXExtractorRunResult? = nil
    ) {
        self.version = version
        self.runID = runID
        self.requestHash = requestHash
        self.backendID = backendID
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.corners = corners
        self.artifacts = artifacts
        self.warnings = warnings
        self.extractorRun = extractorRun
    }

    public func artifact(id: String) -> PEXArtifactRecord? {
        artifacts.first { $0.id == id }
    }

    public func artifacts(kind: PEXArtifactKind, cornerID: PEXCornerID? = nil) -> [PEXArtifactRecord] {
        artifacts.filter { record in
            record.kind == kind && (cornerID == nil || record.cornerID == cornerID)
        }
    }
}

public enum PEXArtifactCompletenessStatus: String, Sendable, Codable, Hashable {
    case complete
    case incomplete
    case invalid
}

public enum PEXArtifactCompletenessIssueKind: String, Sendable, Codable, Hashable {
    case duplicateArtifactID
    case missingArtifact
    case invalidHash
    case missingHash
    case missingByteCount
    case missingIR
    case missingCornerArtifactReference
    case missingFailure
    case failedCorner
    case failedCornerWithoutEvidence
    case pathEscapesRunDirectory
}

public struct PEXArtifactCompletenessIssue: Sendable, Codable, Hashable {
    public let kind: PEXArtifactCompletenessIssueKind
    public let artifactID: String?
    public let cornerID: PEXCornerID?
    public let path: PEXArtifactPath?
    public let message: String

    public init(
        kind: PEXArtifactCompletenessIssueKind,
        artifactID: String? = nil,
        cornerID: PEXCornerID? = nil,
        path: PEXArtifactPath? = nil,
        message: String
    ) {
        self.kind = kind
        self.artifactID = artifactID
        self.cornerID = cornerID
        self.path = path
        self.message = message
    }
}

public struct PEXArtifactCompletenessReport: Sendable, Codable, Hashable {
    public let status: PEXArtifactCompletenessStatus
    public let issues: [PEXArtifactCompletenessIssue]

    public init(status: PEXArtifactCompletenessStatus, issues: [PEXArtifactCompletenessIssue]) {
        self.status = status
        self.issues = issues
    }
}
