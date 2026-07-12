import Foundation

/// Immutable parent/child run history and the effective corner view obtained
/// by applying newer retry results over their parent results.
public struct PEXRunLineage: Sendable, Codable, Hashable {
    public struct Run: Sendable, Codable, Hashable {
        public let runID: PEXRunID
        public let status: PEXRunStatus
        public let resumedFromRunID: PEXRunID?
        public let manifestURL: URL
        public let cornerIDs: [PEXCornerID]

        public init(
            runID: PEXRunID,
            status: PEXRunStatus,
            resumedFromRunID: PEXRunID?,
            manifestURL: URL,
            cornerIDs: [PEXCornerID]
        ) {
            self.runID = runID
            self.status = status
            self.resumedFromRunID = resumedFromRunID
            self.manifestURL = manifestURL
            self.cornerIDs = cornerIDs
        }
    }

    /// Provenance for the result selected for one effective corner.
    public struct EffectiveCorner: Sendable, Codable, Hashable {
        public let cornerID: PEXCornerID
        public let sourceRunID: PEXRunID
        public let status: PEXRunStatus
        public let artifactIDs: [String]
        public let failure: PEXArtifactFailure?

        public init(
            cornerID: PEXCornerID,
            sourceRunID: PEXRunID,
            status: PEXRunStatus,
            artifactIDs: [String] = [],
            failure: PEXArtifactFailure? = nil
        ) {
            self.cornerID = cornerID
            self.sourceRunID = sourceRunID
            self.status = status
            self.artifactIDs = Array(Set(artifactIDs.filter { !$0.isEmpty })).sorted()
            self.failure = failure
        }
    }

    public let rootRunID: PEXRunID
    public let leafRunID: PEXRunID
    public let runs: [Run]
    public let effectiveStatus: PEXRunStatus
    public let effectiveCornerResults: [PEXCornerResult]
    public let effectiveCorners: [EffectiveCorner]

    private enum CodingKeys: String, CodingKey {
        case rootRunID
        case leafRunID
        case runs
        case effectiveStatus
        case effectiveCornerResults
        case effectiveCorners
    }

    public init(results: [PEXRunResult]) {
        let orderedResults = results
        self.rootRunID = orderedResults.first?.runID ?? PEXRunID()
        self.leafRunID = orderedResults.last?.runID ?? self.rootRunID
        self.runs = orderedResults.map { result in
            Run(
                runID: result.runID,
                status: result.status,
                resumedFromRunID: result.resumedFromRunID,
                manifestURL: result.manifestURL,
                cornerIDs: result.cornerResults.map(\.cornerID).sorted { $0.value < $1.value }
            )
        }

        var effectiveByCorner: [PEXCornerID: (runID: PEXRunID, result: PEXCornerResult, corner: PEXArtifactCorner?)] = [:]
        for result in orderedResults {
            for cornerResult in result.cornerResults {
                effectiveByCorner[cornerResult.cornerID] = (
                    result.runID,
                    cornerResult,
                    result.artifacts.corners.first { $0.cornerID == cornerResult.cornerID }
                )
            }
        }
        let effectiveEntries = effectiveByCorner.values.sorted {
            $0.result.cornerID.value < $1.result.cornerID.value
        }
        let effectiveResults = effectiveEntries.map { $0.result }
        self.effectiveCornerResults = effectiveResults
        self.effectiveCorners = effectiveEntries.map { entry in
            EffectiveCorner(
                cornerID: entry.result.cornerID,
                sourceRunID: entry.runID,
                status: entry.result.status,
                artifactIDs: entry.corner?.artifactIDs ?? [],
                failure: entry.corner?.failure
            )
        }
        self.effectiveStatus = Self.status(for: effectiveResults)
    }

    private static func status(for results: [PEXCornerResult]) -> PEXRunStatus {
        let successCount = results.filter { $0.status == .success }.count
        let failureCount = results.filter { $0.status == .failed }.count
        if failureCount == 0, successCount > 0 {
            return .success
        }
        if successCount > 0 {
            return .partialSuccess
        }
        return .failed
    }

    /// Keeps lineage JSON produced before artifact provenance was added
    /// readable. Older snapshots still contain the effective corner results;
    /// their artifact provenance is unavailable, so the leaf run is retained
    /// only as the compatibility source identifier and no artifact IDs are
    /// inferred.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRootRunID = try container.decode(PEXRunID.self, forKey: .rootRunID)
        let decodedLeafRunID = try container.decode(PEXRunID.self, forKey: .leafRunID)
        self.rootRunID = decodedRootRunID
        self.leafRunID = decodedLeafRunID
        self.runs = try container.decode([Run].self, forKey: .runs)
        self.effectiveStatus = try container.decode(PEXRunStatus.self, forKey: .effectiveStatus)
        let decodedCornerResults = try container.decode([PEXCornerResult].self, forKey: .effectiveCornerResults)
        self.effectiveCornerResults = decodedCornerResults
        if let effectiveCorners = try container.decodeIfPresent([EffectiveCorner].self, forKey: .effectiveCorners) {
            self.effectiveCorners = effectiveCorners
        } else {
            self.effectiveCorners = decodedCornerResults.map {
                EffectiveCorner(
                    cornerID: $0.cornerID,
                    sourceRunID: decodedLeafRunID,
                    status: $0.status
                )
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rootRunID, forKey: .rootRunID)
        try container.encode(leafRunID, forKey: .leafRunID)
        try container.encode(runs, forKey: .runs)
        try container.encode(effectiveStatus, forKey: .effectiveStatus)
        try container.encode(effectiveCornerResults, forKey: .effectiveCornerResults)
        try container.encode(effectiveCorners, forKey: .effectiveCorners)
    }
}
