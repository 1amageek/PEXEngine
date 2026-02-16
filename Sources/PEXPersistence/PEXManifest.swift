import Foundation
import PEXCore

public struct PEXManifest: Sendable, Codable {
    public let version: Int
    public let runID: PEXRunID
    public let requestHash: PEXRequestHash
    public let backendID: String
    public let status: PEXRunStatus
    public let startedAt: Date
    public let finishedAt: Date
    public let corners: [CornerEntry]
    public let warnings: [String]

    public struct CornerEntry: Sendable, Codable {
        public let cornerID: PEXCornerID
        public let status: PEXRunStatus
        public let rawFiles: [String]
        public let irFile: String?
        public let logFile: String?

        public init(
            cornerID: PEXCornerID, status: PEXRunStatus,
            rawFiles: [String], irFile: String?, logFile: String?
        ) {
            self.cornerID = cornerID
            self.status = status
            self.rawFiles = rawFiles
            self.irFile = irFile
            self.logFile = logFile
        }
    }

    public static let currentVersion = 1

    public init(
        version: Int = PEXManifest.currentVersion,
        runID: PEXRunID, requestHash: PEXRequestHash,
        backendID: String, status: PEXRunStatus,
        startedAt: Date, finishedAt: Date,
        corners: [CornerEntry], warnings: [String]
    ) {
        self.version = version
        self.runID = runID
        self.requestHash = requestHash
        self.backendID = backendID
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.corners = corners
        self.warnings = warnings
    }
}
