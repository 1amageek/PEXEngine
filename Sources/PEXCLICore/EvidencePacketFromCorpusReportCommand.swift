import Foundation
import PEXEngine

public struct EvidencePacketFromCorpusReportCommand: Sendable {
    public let reportURL: URL
    public let outputURL: URL?
    public let packetID: String?
    public let artifactRootURL: URL?
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        let parsed = try EvidencePacketFromCorpusReportCommandArguments(arguments: arguments)
        self.reportURL = parsed.reportURL
        self.outputURL = parsed.outputURL
        self.packetID = parsed.packetID
        self.artifactRootURL = parsed.artifactRootURL
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
            print("Domain: \(packet.domain)")
            print("Diagnostics: \(packet.diagnostics.count)")
            print("Decision hints: \(packet.decisionHints.count)")
            if let outputURL {
                print("Report: \(outputURL.path(percentEncoded: false))")
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
                "Failed to read SPEF corpus report at \(reportURL.path(percentEncoded: false))",
                underlying: error
            )
        }

        let report: SPEFCorpus.Report
        do {
            report = try JSONDecoder().decode(SPEFCorpus.Report.self, from: reportData)
        } catch {
            throw PEXError.parseFailed(
                cornerID: "spef-corpus",
                message: "Failed to decode SPEF corpus report",
                underlying: error
            )
        }

        return SPEFCorpusEvidencePacketBuilder().build(
            report: report,
            packetID: packetID,
            allowedArtifactRootPath: artifactRootURL?.path(percentEncoded: false)
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
