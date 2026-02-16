import Foundation

public struct PEXCornerResult: Sendable, Codable, Hashable {
    public let cornerID: PEXCornerID
    public let status: PEXRunStatus
    public let ir: ParasiticIR?
    public let rawOutputURLs: [URL]
    public let logURL: URL?
    public let warnings: [PEXWarning]
    public let metrics: PEXCornerMetrics

    public init(
        cornerID: PEXCornerID,
        status: PEXRunStatus,
        ir: ParasiticIR? = nil,
        rawOutputURLs: [URL] = [],
        logURL: URL? = nil,
        warnings: [PEXWarning] = [],
        metrics: PEXCornerMetrics
    ) {
        self.cornerID = cornerID
        self.status = status
        self.ir = ir
        self.rawOutputURLs = rawOutputURLs
        self.logURL = logURL
        self.warnings = warnings
        self.metrics = metrics
    }
}

public struct PEXCornerMetrics: Sendable, Codable, Hashable {
    public let durationSeconds: Double
    public let netCount: Int
    public let elementCount: Int
    public let peakMemoryBytes: Int?

    public init(
        durationSeconds: Double,
        netCount: Int,
        elementCount: Int,
        peakMemoryBytes: Int? = nil
    ) {
        self.durationSeconds = durationSeconds
        self.netCount = netCount
        self.elementCount = elementCount
        self.peakMemoryBytes = peakMemoryBytes
    }
}
