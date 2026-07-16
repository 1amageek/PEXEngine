import Foundation
@_exported import CircuiteFoundation

public enum PEXArtifactKind: String, Sendable, Codable, Hashable, CaseIterable {
    case layoutInput
    case netlistInput
    case technologyInput
    case processProfileDeckInput
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

public struct PEXArtifactDeclaration: Sendable, Codable, Hashable, Identifiable {
    public let id: ArtifactID
    public let locator: ArtifactLocator

    public init(id: ArtifactID, locator: ArtifactLocator) {
        self.id = id
        self.locator = locator
    }
}

public enum PEXArtifactPayload: Sendable, Codable, Hashable {
    case available(ArtifactReference)
    case missing(PEXArtifactDeclaration)
    case omitted(PEXArtifactDeclaration)

    public var id: ArtifactID {
        switch self {
        case .available(let reference): reference.id
        case .missing(let declaration), .omitted(let declaration): declaration.id
        }
    }

    public var locator: ArtifactLocator {
        switch self {
        case .available(let reference): reference.locator
        case .missing(let declaration), .omitted(let declaration): declaration.locator
        }
    }

    public var availability: PEXArtifactAvailability {
        switch self {
        case .available: .available
        case .missing: .missing
        case .omitted: .omitted
        }
    }

    public var reference: ArtifactReference? {
        guard case .available(let reference) = self else { return nil }
        return reference
    }
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
    public let payload: PEXArtifactPayload
    public let stage: PEXStage
    public let cornerID: PEXCornerID?
    public let createdAt: Date
    public let provenance: PEXArtifactProvenance?

    public var id: ArtifactID { payload.id }
    public var locator: ArtifactLocator { payload.locator }
    public var availability: PEXArtifactAvailability { payload.availability }
    public var reference: ArtifactReference? { payload.reference }

    public init(
        payload: PEXArtifactPayload,
        stage: PEXStage,
        cornerID: PEXCornerID? = nil,
        createdAt: Date = Date(),
        provenance: PEXArtifactProvenance? = nil
    ) {
        self.payload = payload
        self.stage = stage
        self.cornerID = cornerID
        self.createdAt = createdAt
        self.provenance = provenance
    }

    public func matches(kind: PEXArtifactKind) -> Bool {
        locator.kind.rawValue == kind.foundationRawValue
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
    ) where IDs.Element == ArtifactID {
        self.init(
            cornerID: cornerID,
            status: status,
            artifactIDs: artifactIDs.map(\.rawValue),
            failure: failure
        )
    }
}

public struct PEXArtifactManifest: Sendable, Codable, Hashable {
    public static let currentVersion = 3

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
        resumedFromRunID: PEXRunID? = nil
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
        self.resumedFromRunID = resumedFromRunID
    }

    public func artifact(id: ArtifactID) -> PEXArtifactRecord? {
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
    public let location: ArtifactLocation?
    public let message: String

    public init(
        kind: PEXArtifactCompletenessIssueKind,
        artifactID: String? = nil,
        cornerID: PEXCornerID? = nil,
        location: ArtifactLocation? = nil,
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
