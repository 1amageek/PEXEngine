import Foundation
import CircuiteFoundation

public struct SPEFCorpusObservationExport: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 2

    public struct ObservationRecord: Sendable, Hashable, Codable {
        public let recordID: String
        public let artifact: ArtifactReference
        public let observations: SPEFCorpus.EvaluationSummary
        public let observedAt: String

        public init(
            recordID: String,
            artifact: ArtifactReference,
            observations: SPEFCorpus.EvaluationSummary,
            observedAt: String
        ) {
            self.recordID = recordID
            self.artifact = artifact
            self.observations = observations
            self.observedAt = observedAt
        }
    }

    public let schemaVersion: Int
    public let status: String
    public let reportPath: String
    public let reportArtifact: ArtifactReference
    public let summary: SPEFCorpus.Summary
    public let observationRecord: ObservationRecord

    public init(
        schemaVersion: Int = SPEFCorpusObservationExport.currentSchemaVersion,
        reportPath: String,
        reportSHA256: String,
        reportByteCount: UInt64,
        report: SPEFCorpus.Report,
        recordID: String? = nil,
        observedAt: Date = Date()
    ) throws {
        let artifact = try ArtifactReference(
            digest: try ContentDigest(
                algorithm: .sha256,
                hexadecimalValue: reportSHA256
            ),
            byteCount: reportByteCount,
            descriptor: ArtifactDescriptor(
                role: .input,
                kind: .report,
                format: .json
            ),
        )
        self.schemaVersion = schemaVersion
        self.status = report.evaluation.passed ? "passed" : "failed"
        self.reportPath = reportPath
        self.reportArtifact = artifact
        self.summary = report.summary
        self.observationRecord = ObservationRecord(
            recordID: recordID ?? Self.defaultRecordID(reportPath: reportPath),
            artifact: artifact,
            observations: report.observationSummary,
            observedAt: Self.iso8601String(from: observedAt)
        )
    }

    public var reportSHA256: String { reportArtifact.digest.hexadecimalValue }

    private static func defaultRecordID(reportPath: String) -> String {
        let filename = URL(filePath: reportPath).deletingPathExtension().lastPathComponent
        return filename.isEmpty ? "pex-spef-corpus" : "pex-spef-corpus:\(filename)"
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }
}
