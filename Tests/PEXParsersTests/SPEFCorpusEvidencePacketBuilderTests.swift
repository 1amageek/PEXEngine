import Foundation
import CircuiteFoundation
import CircuiteFoundationFoundation
import Testing
@testable import PEXCore
@testable import PEXParsers

@Suite("SPEF corpus evidence packet builder")
struct SPEFCorpusEvidencePacketBuilderTests {
    @Test func evidencePacketQuarantinesUnsafeCorpusArtifactPaths() throws {
        let root = try makeTemporaryDirectory(prefix: "spef-corpus-evidence-artifacts")
        defer { removeTemporaryItem(root) }

        let validFixturePath = root.appending(path: "valid.spef").path(percentEncoded: false)
        let outsideFixturePath = root
            .deletingLastPathComponent()
            .appending(path: "outside.spef")
            .path(percentEncoded: false)
        let report = try makeReport(
            root: root,
            fixtures: [
                fixture(fileName: "valid.spef", sourcePath: validFixturePath),
                fixture(fileName: "outside.spef", sourcePath: outsideFixturePath),
                fixture(fileName: "remote.spef", sourcePath: "https://example.invalid/remote.spef"),
            ],
            caseResults: [
                passingCase(fileName: "valid.spef"),
                passingCase(fileName: "outside.spef"),
                passingCase(fileName: "remote.spef"),
            ]
        )

        let packet = SPEFCorpusEvidencePacketBuilder().build(
            report: report,
            packetID: "unsafe-corpus-artifacts",
            allowedArtifactRootPath: root.path(percentEncoded: false)
        )

        #expect(packet.inputs.contains { $0.logicalID == "corpus-manifest" })
        #expect(packet.inputs.contains { $0.logicalID == "corpus-input-1" })
        #expect(!packet.inputs.contains { $0.logicalID == "corpus-input-2" })
        #expect(!packet.inputs.contains { $0.logicalID == "corpus-input-3" })
        #expect(packet.artifacts.isEmpty)

        #expect(throws: (any Error).self) {
            try ArtifactLocation(workspaceRelativePath: "https://example.invalid/remote.spef")
        }

        let integrityDiagnostics = packet.diagnostics.filter { $0.category == "artifact_integrity" }
        #expect(integrityDiagnostics.contains { $0.observedText == outsideFixturePath })
        #expect(packet.readiness.contains {
            $0.component == "spef-corpus-artifacts" && $0.status == .blocked
        })
        #expect(packet.confidence.level == .low)
        #expect(packet.decisionHints.contains { $0.action == "inspect_spef_corpus_artifact_paths" })
    }

    @Test func evidencePacketUsesSafeCorpusCaseNamespaces() throws {
        let root = try makeTemporaryDirectory(prefix: "spef-corpus-evidence-cases")
        defer { removeTemporaryItem(root) }

        let report = try makeReport(
            root: root,
            fixtures: [
                fixture(fileName: "case/one.spef", sourcePath: root.appending(path: "case-one-a.spef").path(percentEncoded: false)),
                fixture(fileName: "case one.spef", sourcePath: root.appending(path: "case-one-b.spef").path(percentEncoded: false)),
                fixture(fileName: "case/one.spef", sourcePath: root.appending(path: "case-one-c.spef").path(percentEncoded: false)),
            ],
            caseResults: [
                failingCase(fileName: "case/one.spef"),
                failingCase(fileName: "case one.spef"),
                failingCase(fileName: "case/one.spef"),
            ]
        )

        let packet = SPEFCorpusEvidencePacketBuilder().build(
            report: report,
            packetID: "unsafe-corpus-cases",
            allowedArtifactRootPath: root.path(percentEncoded: false)
        )

        let failureCaseIDs = packet.diagnostics
            .filter { $0.category == "parse_failure" }
            .compactMap(\.caseID)
        #expect(failureCaseIDs == ["case-one.spef", "case-one.spef-2", "case-one.spef-3"])
        #expect(packet.diagnostics.compactMap(\.caseID).allSatisfy {
            !$0.contains("/") && !$0.contains(" ")
        })
        #expect(packet.diagnostics.allSatisfy {
            !$0.diagnosticID.contains("/") && !$0.diagnosticID.contains(" ")
        })
        #expect(packet.diagnostics.contains {
            $0.category == "artifact_integrity" && $0.code == "unsafe_case_id"
        })
        #expect(packet.diagnostics.contains {
            $0.category == "artifact_integrity" && $0.code == "duplicate_case_id"
        })
        #expect(packet.diagnostics.contains {
            $0.category == "artifact_integrity" && $0.code == "case_id_namespace_collision"
        })
        #expect(packet.readiness.contains {
            $0.component == "spef-corpus-artifacts" && $0.status == .blocked
        })
        #expect(packet.confidence.level == .low)
    }
}

private func makeReport(
    root: URL,
    fixtures: [SPEFCorpus.Fixture],
    caseResults: [SPEFCorpus.CaseResult]
) throws -> SPEFCorpus.Report {
    let manifest = SPEFCorpus.Manifest(
        schemaVersion: 1,
        sourceRepository: "local-fixtures",
        pinnedCommit: "test",
        sourceDirectory: root.path(percentEncoded: false),
        license: "test",
        fixtures: fixtures
    )
    let summary = SPEFCorpus.Summary(caseResults: caseResults)
    let evaluation = manifest.evaluationPolicy.evaluate(summary: summary)
    return SPEFCorpus.Report(
        manifestPath: root.appending(path: "fixture-manifest.json").path(percentEncoded: false),
        manifest: manifest,
        sourceArtifacts: try makeArtifactReferences(root: root, fixtures: fixtures),
        summary: summary,
        evaluation: evaluation,
        caseResults: caseResults
    )
}

private func makeArtifactReferences(
    root: URL,
    fixtures: [SPEFCorpus.Fixture]
) throws -> [SPEFCorpus.SourceArtifact] {
    var references = [SPEFCorpus.SourceArtifact(
        logicalID: "corpus-manifest",
        reference: try ArtifactReference(
            digest: try ContentDigest(
                algorithm: .sha256,
                hexadecimalValue: String(repeating: "a", count: 64)
            ),
            byteCount: 128,
            descriptor: ArtifactDescriptor(role: .input, kind: .other, format: .json)
        ),
        path: root.appending(path: "fixture-manifest.json").path(percentEncoded: false)
    )]
    for (index, fixture) in fixtures.enumerated() {
        guard !fixture.sourcePath.contains("://") else { continue }
        references.append(SPEFCorpus.SourceArtifact(
            logicalID: "corpus-input-\(index + 1)",
            reference: try ArtifactReference(
                digest: try ContentDigest(
                    algorithm: .sha256,
                    hexadecimalValue: String(repeating: String(index % 10), count: 64)
                ),
                byteCount: UInt64(fixture.byteCount),
                descriptor: ArtifactDescriptor(role: .input, kind: .parasitics, format: .spef)
            ),
            path: fixture.sourcePath
        ))
    }
    return references
}

private func fixture(fileName: String, sourcePath: String) -> SPEFCorpus.Fixture {
    SPEFCorpus.Fixture(
        fileName: fileName,
        sourcePath: sourcePath,
        gitBlobSHA: "blob-\(fileName)",
        sha256: "sha-\(fileName)",
        byteCount: 128,
        designName: "top",
        coverageTags: ["pex.physical-value"],
        parseSummary: parseSummary(),
        loweredSummary: loweredSummary()
    )
}

private func passingCase(fileName: String) -> SPEFCorpus.CaseResult {
    SPEFCorpus.CaseResult(
        fileName: fileName,
        designName: "top",
        passed: true,
        coverageTags: ["pex.physical-value"],
        observedParseSummary: parseSummary(),
        observedLoweredSummary: loweredSummary()
    )
}

private func failingCase(fileName: String) -> SPEFCorpus.CaseResult {
    SPEFCorpus.CaseResult(
        fileName: fileName,
        designName: "top",
        passed: false,
        coverageTags: ["pex.physical-value"],
        failures: [
            SPEFCorpus.CaseFailure(
                code: "parse_failed",
                category: "parse_failure",
                message: "The SPEF fixture could not be parsed.",
                suggestedActions: ["inspect_spef_syntax"]
            ),
        ]
    )
}

private func parseSummary() -> SPEFCorpus.ParseSummary {
    SPEFCorpus.ParseSummary(
        nameMapCount: 1,
        portCount: 1,
        netCount: 1,
        connectionCount: 1,
        capacitorCount: 1,
        resistorCount: 1
    )
}

private func loweredSummary() -> SPEFCorpus.LoweredSummary {
    SPEFCorpus.LoweredSummary(
        netCount: 1,
        elementCount: 2,
        capacitorElementCount: 1,
        couplingElementCount: 0,
        resistorElementCount: 1,
        totalGroundCapF: 1e-15,
        totalCouplingCapF: 0,
        totalResistanceOhm: 1,
        capTolerance: 1e-18
    )
}

private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeTemporaryItem(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
    }
}
