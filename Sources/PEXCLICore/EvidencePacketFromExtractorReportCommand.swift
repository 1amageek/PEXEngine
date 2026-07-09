import Foundation
import PEXEngine

public struct EvidencePacketFromExtractorReportCommand: Sendable {
    public let reportURL: URL
    public let outputURL: URL?
    public let packetID: String?
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        let parsed = try EvidencePacketFromExtractorReportCommandArguments(arguments: arguments)
        self.reportURL = parsed.reportURL
        self.outputURL = parsed.outputURL
        self.packetID = parsed.packetID
        self.jsonOutput = parsed.jsonOutput
    }

    @discardableResult
    public func run() async throws -> Bool {
        let packet = try buildPacket()
        if let outputURL {
            try writePacket(packet, to: outputURL)
        }

        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(packet)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("Packet: \(packet.packetID)")
            print("Backend: \(packet.subject.backendID ?? "unknown")")
            print("Diagnostics: \(packet.diagnostics.count)")
            print("Decision hints: \(packet.decisionHints.count)")
            if let outputURL {
                print("Packet path: \(outputURL.path(percentEncoded: false))")
            }
        }
        return true
    }

    public func buildPacket() throws -> PEXEvidencePacket {
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

        return PEXExternalExtractorEvidencePacketBuilder().build(
            report: report,
            packetID: packetID,
            allowedArtifactRootPath: reportURL.deletingLastPathComponent().path(percentEncoded: false)
        )
    }

    private func writePacket(_ packet: PEXEvidencePacket, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(packet)
            try data.write(to: url, options: .atomic)
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to write PEX evidence packet to \(url.path(percentEncoded: false))",
                underlying: error
            )
        }
    }
}
