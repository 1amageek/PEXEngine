import Foundation

public struct PEXRunResult: Sendable, Codable, Hashable {
    public let runID: PEXRunID
    public let requestHash: PEXRequestHash
    public let status: PEXRunStatus
    public let startedAt: Date
    public let finishedAt: Date
    public let cornerResults: [PEXCornerResult]
    public let warnings: [PEXWarning]
    public let artifacts: PEXArtifactIndex
    public let metrics: PEXRunMetrics

    public init(
        runID: PEXRunID,
        requestHash: PEXRequestHash,
        status: PEXRunStatus,
        startedAt: Date,
        finishedAt: Date,
        cornerResults: [PEXCornerResult],
        warnings: [PEXWarning],
        artifacts: PEXArtifactIndex,
        metrics: PEXRunMetrics
    ) {
        self.runID = runID
        self.requestHash = requestHash
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.cornerResults = cornerResults
        self.warnings = warnings
        self.artifacts = artifacts
        self.metrics = metrics
    }
}
