import CryptoKit
import Foundation
import PEXEngine

public struct EvidenceFromCorpusReportCommand: Sendable {
    public let reportURL: URL
    public let evidenceID: String?
    public let checkedAt: Date
    public let jsonOutput: Bool

    public init(arguments: [String], now: Date = Date()) throws {
        let parsed = try EvidenceFromCorpusReportCommandArguments(arguments: arguments, now: now)
        self.reportURL = parsed.reportURL
        self.evidenceID = parsed.evidenceID
        self.checkedAt = parsed.checkedAt
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
            print("Evidence: \(output.toolEvidence.evidenceID)")
            print("Report: \(output.reportPath)")
        }
        return output.toolEvidence.qualification.qualified
    }

    public func buildExport() throws -> SPEFCorpusToolEvidenceExport {
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

        return SPEFCorpusToolEvidenceExport(
            reportPath: reportURL.path(percentEncoded: false),
            reportSHA256: Self.sha256Hex(reportData),
            report: report,
            evidenceID: evidenceID,
            checkedAt: checkedAt
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
