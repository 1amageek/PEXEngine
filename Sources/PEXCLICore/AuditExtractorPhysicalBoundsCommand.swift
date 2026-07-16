import Foundation
import PEXEngine

public struct AuditExtractorPhysicalBoundsCommand: Sendable {
    public let reportURL: URL
    public let outputURL: URL?
    public let auditID: String?
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        let parsed = try AuditExtractorPhysicalBoundsCommandArguments(arguments: arguments)
        self.reportURL = parsed.reportURL
        self.outputURL = parsed.outputURL
        self.auditID = parsed.auditID
        self.jsonOutput = parsed.jsonOutput
    }

    @discardableResult
    public func run() async throws -> Bool {
        let audit = try buildAudit()
        if let outputURL {
            try writeAudit(audit, to: outputURL)
        }

        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(audit)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("Status: \(audit.status.rawValue)")
            print("Backend: \(audit.extractorBackendID)")
            print("Physical bounds: \(audit.summary.passedMetricCount)/\(audit.summary.declaredMetricCount) passed")
            print("Diagnostics: \(audit.diagnostics.count)")
            if let outputURL {
                print("Audit path: \(outputURL.path(percentEncoded: false))")
            }
        }
        return audit.status == .satisfied
    }

    public func buildAudit() throws -> PEXExternalExtractorPhysicalBoundsAudit {
        let reportData: Data
        do {
            reportData = try Data(contentsOf: reportURL)
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to read PEX external extractor report at \(reportURL.path(percentEncoded: false))",
                underlying: error
            )
        }

        let report: PEXExternalExtractorCorpusReport
        do {
            report = try JSONDecoder().decode(PEXExternalExtractorCorpusReport.self, from: reportData)
        } catch {
            throw PEXError.parseFailed(
                cornerID: "external-pex",
                message: "Failed to decode PEX external extractor report",
                underlying: error
            )
        }

        return PEXExternalExtractorPhysicalBoundsAuditor().audit(
            report: report,
            reportPath: reportURL.path(percentEncoded: false),
            auditID: auditID
        )
    }

    private func writeAudit(_ audit: PEXExternalExtractorPhysicalBoundsAudit, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(audit)
            try data.write(to: url, options: .atomic)
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to write PEX physical bounds audit to \(url.path(percentEncoded: false))",
                underlying: error
            )
        }
    }
}
