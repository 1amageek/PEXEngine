import Foundation
import CircuiteFoundation

public enum PEXArtifactKind: String, Sendable, Codable, Hashable, CaseIterable {
    case layoutInput
    case netlistInput
    case technologyInput
    case processProfileDeckInput
    case processDriver
    case processEvidence
    case sourceConnectivityReport
    case request
    case rawOutput
    case log
    case parasiticIR
    case spefRoundTrip
    case spiceBackannotation
    case report
}

public enum PEXArtifactAvailability: String, Sendable, Codable, Hashable {
    case available
    case missing
    case omitted
}

public enum PEXArtifactManifestError: Error, Sendable, Equatable {
    case unsupportedVersion(Int)
    case evidenceProvenanceMismatch
    case evidenceArtifactsMismatch
}

public struct PEXArtifactProvenance: Sendable, Codable, Hashable {
    public let sourcePath: String?
    public let note: String?

    public init(sourcePath: String? = nil, note: String? = nil) {
        self.sourcePath = sourcePath
        self.note = note
    }
}

extension PEXArtifactKind {
    public var foundationRawValue: String { "pex.\(rawValue)" }
}

public struct PEXArtifactFailure: Sendable, Codable, Hashable {
    public let stage: PEXStage
    public let failureKind: PEXErrorKind?
    public let message: String
    public let suggestedActions: [String]

    public init(stage: PEXStage, message: String, suggestedActions: [String] = []) {
        self.failureKind = nil
        self.stage = stage
        self.message = message
        self.suggestedActions = suggestedActions
    }

    public init(
        stage: PEXStage,
        failureKind: PEXErrorKind?,
        message: String,
        suggestedActions: [String] = []
    ) {
        self.stage = stage
        self.failureKind = failureKind
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

    public init<IDs: Sequence>(
        cornerID: PEXCornerID,
        status: PEXRunStatus,
        artifactIDs: IDs,
        failure: PEXArtifactFailure? = nil
    ) where IDs.Element == PEXArtifactRecordID {
        self.init(
            cornerID: cornerID,
            status: status,
            artifactIDs: artifactIDs.map(\.rawValue),
            failure: failure
        )
    }
}

public struct PEXArtifactManifest: Sendable, Codable, Hashable {
    public static let currentVersion = 5

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
    public let resumedFromRunID: PEXRunID?
    public let backendExecutions: [PEXBackendExecutionIdentity]
    public let provenance: ExecutionProvenance
    public let evidence: EvidenceManifest

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
        extractorRun: PEXExtractorRunResult? = nil,
        resumedFromRunID: PEXRunID? = nil,
        backendExecutions: [PEXBackendExecutionIdentity] = [],
        provenance: ExecutionProvenance,
        evidence: EvidenceManifest
    ) throws {
        guard version == Self.currentVersion else {
            throw PEXArtifactManifestError.unsupportedVersion(version)
        }
        guard evidence.provenance == provenance else {
            throw PEXArtifactManifestError.evidenceProvenanceMismatch
        }
        guard evidence.artifacts == artifacts.compactMap(\.reference) else {
            throw PEXArtifactManifestError.evidenceArtifactsMismatch
        }
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
        self.resumedFromRunID = resumedFromRunID
        self.backendExecutions = backendExecutions
        self.provenance = provenance
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case version, runID, requestHash, backendID, status, startedAt, finishedAt
        case corners, artifacts, warnings, extractorRun, resumedFromRunID
        case backendExecutions, provenance, evidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported PEX artifact manifest version \(version)."
            )
        }
        try self.init(
            version: version,
            runID: container.decode(PEXRunID.self, forKey: .runID),
            requestHash: container.decode(PEXRequestHash.self, forKey: .requestHash),
            backendID: container.decode(String.self, forKey: .backendID),
            status: container.decode(PEXRunStatus.self, forKey: .status),
            startedAt: container.decode(Date.self, forKey: .startedAt),
            finishedAt: container.decode(Date.self, forKey: .finishedAt),
            corners: container.decode([PEXArtifactCorner].self, forKey: .corners),
            artifacts: container.decode([PEXArtifactRecord].self, forKey: .artifacts),
            warnings: container.decode([PEXWarning].self, forKey: .warnings),
            extractorRun: container.decodeIfPresent(PEXExtractorRunResult.self, forKey: .extractorRun),
            resumedFromRunID: container.decodeIfPresent(PEXRunID.self, forKey: .resumedFromRunID),
            backendExecutions: container.decodeIfPresent(
                [PEXBackendExecutionIdentity].self,
                forKey: .backendExecutions
            ) ?? [],
            provenance: container.decode(ExecutionProvenance.self, forKey: .provenance),
            evidence: container.decode(EvidenceManifest.self, forKey: .evidence)
        )
    }

    public func artifact(id: PEXArtifactRecordID) -> PEXArtifactRecord? {
        artifacts.first { $0.id == id }
    }

    public func artifacts(kind: PEXArtifactKind, cornerID: PEXCornerID? = nil) -> [PEXArtifactRecord] {
        artifacts.filter { record in
            record.matches(kind: kind) && (cornerID == nil || record.cornerID == cornerID)
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
    public let location: ArtifactRelativePath?
    public let message: String

    public init(
        kind: PEXArtifactCompletenessIssueKind,
        artifactID: String? = nil,
        cornerID: PEXCornerID? = nil,
        location: ArtifactRelativePath? = nil,
        message: String
    ) {
        self.kind = kind
        self.artifactID = artifactID
        self.cornerID = cornerID
        self.location = location
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
