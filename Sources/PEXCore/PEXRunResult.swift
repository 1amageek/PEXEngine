import Foundation

public struct PEXRunResult: Sendable, Codable, Hashable {
    public let runID: PEXRunID
    public let requestHash: PEXRequestHash
    public let status: PEXRunStatus
    public let startedAt: Date
    public let finishedAt: Date
    public let cornerResults: [PEXCornerResult]
    public let warnings: [PEXWarning]
    public let artifacts: PEXArtifactManifest
    public let manifestURL: URL
    public let metrics: PEXRunMetrics
    public let extractorRun: PEXExtractorRunResult?
    public let resumedFromRunID: PEXRunID?

    public init(
        runID: PEXRunID,
        requestHash: PEXRequestHash,
        status: PEXRunStatus,
        startedAt: Date,
        finishedAt: Date,
        cornerResults: [PEXCornerResult],
        warnings: [PEXWarning],
        artifacts: PEXArtifactManifest,
        manifestURL: URL,
        metrics: PEXRunMetrics,
        extractorRun: PEXExtractorRunResult? = nil,
        resumedFromRunID: PEXRunID? = nil
    ) {
        self.runID = runID
        self.requestHash = requestHash
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.cornerResults = cornerResults
        self.warnings = warnings
        self.artifacts = artifacts
        self.manifestURL = manifestURL
        self.metrics = metrics
        self.extractorRun = extractorRun
        self.resumedFromRunID = resumedFromRunID
    }
}
