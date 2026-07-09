import Testing
@testable import PEXCLICore
@testable import PEXCore

@Suite("PEX evidence CLI argument boundaries")
struct PEXEvidenceCLIArgumentBoundaryTests {
    @Test func parseCorpusRejectsOptionTokenAsOptionValue() {
        expectInvalidInput("parse-corpus manifest", contains: "--manifest requires a value") {
            _ = try ParseCorpusCommand(arguments: ["--manifest", "--json"])
        }
        expectInvalidInput("parse-corpus fixtures", contains: "--fixtures-dir requires a value") {
            _ = try ParseCorpusCommand(arguments: [
                "--manifest",
                "/tmp/fixture-manifest.json",
                "--fixtures-dir",
                "--out",
            ])
        }
        expectInvalidInput("parse-corpus output", contains: "--out requires a value") {
            _ = try ParseCorpusCommand(arguments: [
                "--manifest",
                "/tmp/fixture-manifest.json",
                "--out",
                "--json",
            ])
        }
    }

    @Test func evidenceFromCorpusReportRejectsOptionTokenAsOptionValue() {
        expectInvalidInput("evidence report", contains: "--report requires a value") {
            _ = try EvidenceFromCorpusReportCommand(arguments: ["--report", "--json"])
        }
        expectInvalidInput("evidence id", contains: "--evidence-id requires a value") {
            _ = try EvidenceFromCorpusReportCommand(arguments: [
                "--report",
                "/tmp/pex-spef-corpus-report.json",
                "--evidence-id",
                "--checked-at",
            ])
        }
        expectInvalidInput("checked at", contains: "--checked-at requires a value") {
            _ = try EvidenceFromCorpusReportCommand(arguments: [
                "--report",
                "/tmp/pex-spef-corpus-report.json",
                "--checked-at",
                "--json",
            ])
        }
        expectInvalidInput("checked at format", contains: "--checked-at must be an ISO 8601 timestamp") {
            _ = try EvidenceFromCorpusReportCommand(arguments: [
                "--report",
                "/tmp/pex-spef-corpus-report.json",
                "--checked-at",
                "not-a-date",
            ])
        }
    }

    @Test func evidencePacketCommandsRejectOptionTokenAsOptionValue() {
        expectInvalidInput("corpus packet report", contains: "--report requires a value") {
            _ = try EvidencePacketFromCorpusReportCommand(arguments: ["--report", "--json"])
        }
        expectInvalidInput("corpus packet output", contains: "--out requires a value") {
            _ = try EvidencePacketFromCorpusReportCommand(arguments: [
                "--report",
                "/tmp/pex-corpus-report.json",
                "--out",
                "--packet-id",
            ])
        }
        expectInvalidInput("corpus packet id", contains: "--packet-id requires a value") {
            _ = try EvidencePacketFromCorpusReportCommand(arguments: [
                "--report",
                "/tmp/pex-corpus-report.json",
                "--packet-id",
                "--json",
            ])
        }
        expectInvalidInput("corpus packet artifact root", contains: "--artifact-root requires a value") {
            _ = try EvidencePacketFromCorpusReportCommand(arguments: [
                "--report",
                "/tmp/pex-corpus-report.json",
                "--artifact-root",
                "--json",
            ])
        }
        expectInvalidInput("extractor packet report", contains: "--report requires a value") {
            _ = try EvidencePacketFromExtractorReportCommand(arguments: ["--report", "--json"])
        }
        expectInvalidInput("extractor packet output", contains: "--out requires a value") {
            _ = try EvidencePacketFromExtractorReportCommand(arguments: [
                "--report",
                "/tmp/pex-extractor-report.json",
                "--out",
                "--packet-id",
            ])
        }
        expectInvalidInput("extractor packet id", contains: "--packet-id requires a value") {
            _ = try EvidencePacketFromExtractorReportCommand(arguments: [
                "--report",
                "/tmp/pex-extractor-report.json",
                "--packet-id",
                "--json",
            ])
        }
        expectInvalidInput("physical bounds report", contains: "--report requires a value") {
            _ = try AuditExtractorPhysicalBoundsCommand(arguments: ["--report", "--json"])
        }
        expectInvalidInput("physical bounds output", contains: "--out requires a value") {
            _ = try AuditExtractorPhysicalBoundsCommand(arguments: [
                "--report",
                "/tmp/pex-extractor-report.json",
                "--out",
                "--audit-id",
            ])
        }
        expectInvalidInput("physical bounds audit id", contains: "--audit-id requires a value") {
            _ = try AuditExtractorPhysicalBoundsCommand(arguments: [
                "--report",
                "/tmp/pex-extractor-report.json",
                "--audit-id",
                "--json",
            ])
        }
    }

    private func expectInvalidInput(_ label: String, contains expectedMessage: String, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("Expected invalid input for \(label)")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains(expectedMessage))
        } catch {
            Issue.record("Expected PEXError.invalidInput for \(label), got \(error)")
        }
    }
}
