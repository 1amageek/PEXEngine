import CryptoKit
import Foundation
import PEXEngine

public struct ObservationFromCorpusReportCommand: Sendable {
    public let reportURL: URL
    public let recordID: String?
    public let observedAt: Date
    public let jsonOutput: Bool

    public init(arguments: [String], now: Date = Date()) throws {
        let parsed = try ObservationFromCorpusReportCommandArguments(arguments: arguments, now: now)
        self.reportURL = parsed.reportURL
        self.recordID = parsed.recordID
        self.observedAt = parsed.observedAt
        self.jsonOutput = parsed.jsonOutput
    }

    @discardableResult
    public func run() async throws -> Bool {
        let output = try buildExport()
        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(output)
            print(String(data: jsonData, encoding: .utf8) ?? "{}")
        } else {
            print("Status: \(output.status)")
            print("Observation: \(output.observationRecord.recordID)")
            print("Report: \(output.reportPath)")
        }
        return output.observationRecord.observations.passed
    }

    public func buildExport() throws -> SPEFCorpusObservationExport {
        let reportData: Data
        do {
            reportData = try Data(contentsOf: reportURL)
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to read SPEF corpus report from \(reportURL.path(percentEncoded: false))",
                underlying: error
            )
        }

        let report: SPEFCorpus.Report
        do {
            report = try JSONDecoder().decode(SPEFCorpus.Report.self, from: reportData)
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to decode SPEF corpus report from \(reportURL.path(percentEncoded: false))",
                underlying: error
            )
        }

        return try SPEFCorpusObservationExport(
            reportPath: reportURL.path(percentEncoded: false),
            reportSHA256: Self.sha256Hex(reportData),
            reportByteCount: UInt64(reportData.count),
            report: report,
            recordID: recordID,
            observedAt: observedAt
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
