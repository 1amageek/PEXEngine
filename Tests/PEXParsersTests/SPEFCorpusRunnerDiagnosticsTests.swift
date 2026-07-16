import CryptoKit
import Foundation
import Testing
@testable import PEXParsers

@Suite("SPEF Corpus Runner Diagnostics")
struct SPEFCorpusRunnerDiagnosticsTests {
    @Test("SPEF corpus manifest rejects missing current physical fields")
    func manifestRejectsMissingCurrentPhysicalFields() {
        let data = Data("""
        {
          "schemaVersion": 1,
          "sourceRepository": "https://example.invalid/source",
          "pinnedCommit": "revision",
          "sourceDirectory": "fixtures",
          "license": "test",
          "evaluationPolicy": {
            "requireCorpusPassed": true,
            "minimumPassRate": 1,
            "requiredCoverageTags": []
          },
          "fixtures": [
            {
              "fileName": "fixture.spef",
              "sourcePath": "fixture.spef",
              "gitBlobSHA": "blob",
              "sha256": "hash",
              "byteCount": 1,
              "designName": "top",
              "coverageTags": [],
              "parseSummary": {
                "nameMapCount": 0,
                "portCount": 0,
                "netCount": 0,
                "connectionCount": 0,
                "capacitorCount": 0,
                "resistorCount": 0
              },
              "loweredSummary": {
                "netCount": 0,
                "elementCount": 0,
                "capacitorElementCount": 0,
                "couplingElementCount": 0,
                "resistorElementCount": 0,
                "inductorElementCount": 0,
                "totalGroundCapF": 0,
                "totalCouplingCapF": 0,
                "totalResistanceOhm": 0,
                "totalInductanceH": 0,
                "capTolerance": 0,
                "resistanceTolerance": 0,
                "inductanceTolerance": 0
              }
            }
          ]
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SPEFCorpus.Manifest.self, from: data)
        }
    }

    @Test("SPEF corpus report rejects missing source artifact inventory")
    func reportRejectsMissingSourceArtifactInventory() throws {
        let corpus = try makeEmptyCorpus()
        defer { removeTemporaryItem(corpus.directory) }
        let report = try SPEFCorpusRunner().run(manifestURL: corpus.manifestURL)
        let encoded = try JSONEncoder().encode(report)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "sourceArtifacts")
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SPEFCorpus.Report.self, from: data)
        }
    }

    @Test("SPEF corpus reports physical bound failures with observed expected tolerance")
    func corpusReportsPhysicalBoundFailuresWithObservedExpectedTolerance() throws {
        let corpus = try makePhysicalBoundCorpus()
        defer { removeTemporaryItem(corpus.directory) }

        let report = try SPEFCorpusRunner().run(manifestURL: corpus.manifestURL)

        #expect(report.status == "failed")
        #expect(report.summary.caseCount == 1)
        #expect(report.summary.failedCaseCount == 1)
        #expect(report.summary.failureCodeCounts["total_ground_cap_mismatch"] == 1)
        #expect(report.summary.failureCategoryCounts["physical_bound_mismatch"] == 1)
        #expect(report.evaluation.passed == false)
        #expect(report.evaluation.failures.contains { $0.code == "corpus_not_passed" })
        #expect(report.observationSummary.observedCounts["failureOccurrenceCount"] == 1)
        #expect(report.observationSummary.observedCounts["failureCategoryKindCount"] == 1)

        let caseResult = try #require(report.caseResults.first)
        let fixture = try #require(corpus.manifest.fixtures.first)
        #expect(caseResult.observedParseSummary == fixture.parseSummary)
        #expect(caseResult.observedLoweredSummary?.totalGroundCapF == 2e-15)

        let failure = try #require(caseResult.failures.first { $0.code == "total_ground_cap_mismatch" })
        #expect(failure.category == "physical_bound_mismatch")
        #expect(failure.observedDouble == 2e-15)
        #expect(failure.expectedDouble == 3e-15)
        #expect(failure.tolerance == 1e-18)
        #expect(failure.suggestedActions.contains("check_extractor_units"))
        #expect(failure.suggestedActions.contains("inspect_top_parasitic_nets"))
    }

    @Test("SPEF corpus does not qualify an empty fixture manifest")
    func corpusRejectsEmptyFixtureManifest() throws {
        let corpus = try makeEmptyCorpus()
        defer { removeTemporaryItem(corpus.directory) }

        let report = try SPEFCorpusRunner().run(manifestURL: corpus.manifestURL)

        #expect(report.status == "failed")
        #expect(report.summary.caseCount == 0)
        #expect(report.summary.passRate == 1)
        #expect(report.evaluation.passed == false)
        #expect(report.evaluation.failures.contains { $0.code == "corpus_empty" })
        #expect(report.observationSummary.failureCodes.contains("corpus_empty"))
        #expect(report.observationSummary.observedCounts["caseCount"] == 0)
    }
}

private struct SPEFCorpusRunnerTestCorpus {
    var directory: URL
    var manifestURL: URL
    var manifest: SPEFCorpus.Manifest
}

private func makePhysicalBoundCorpus() throws -> SPEFCorpusRunnerTestCorpus {
    let directory = try makeTemporaryDirectory(prefix: "spef-corpus-diagnostics")
    let fixtureData = Data(diagnosticSPEF.utf8)
    try fixtureData.write(to: directory.appending(path: "unit.spef"))

    let manifest = SPEFCorpus.Manifest(
        schemaVersion: 1,
        sourceRepository: "local-test-corpus",
        pinnedCommit: "local",
        sourceDirectory: ".",
        license: "test-fixture",
        evaluationPolicy: SPEFCorpus.EvaluationPolicy(
            minimumPassRate: 1,
            requiredCoverageTags: ["pex.physical-value"]
        ),
        fixtures: [
            SPEFCorpus.Fixture(
                fileName: "unit.spef",
                sourcePath: "unit.spef",
                gitBlobSHA: "local",
                sha256: sha256Hex(fixtureData),
                byteCount: fixtureData.count,
                designName: "unit",
                coverageTags: ["pex.physical-value", "pex.spef.openroad"],
                parseSummary: SPEFCorpus.ParseSummary(
                    nameMapCount: 0,
                    portCount: 2,
                    netCount: 1,
                    connectionCount: 2,
                    capacitorCount: 2,
                    resistorCount: 1
                ),
                loweredSummary: SPEFCorpus.LoweredSummary(
                    netCount: 2,
                    elementCount: 3,
                    capacitorElementCount: 1,
                    couplingElementCount: 1,
                    resistorElementCount: 1,
                    totalGroundCapF: 3e-15,
                    totalCouplingCapF: 1e-15,
                    totalResistanceOhm: 5,
                    capTolerance: 1e-18,
                    resistanceTolerance: 1e-9
                )
            ),
        ]
    )
    let manifestURL = try writeManifest(manifest, in: directory)
    return SPEFCorpusRunnerTestCorpus(directory: directory, manifestURL: manifestURL, manifest: manifest)
}

private func makeEmptyCorpus() throws -> SPEFCorpusRunnerTestCorpus {
    let directory = try makeTemporaryDirectory(prefix: "spef-empty-corpus")
    let manifest = SPEFCorpus.Manifest(
        schemaVersion: 1,
        sourceRepository: "local-empty-corpus",
        pinnedCommit: "local",
        sourceDirectory: ".",
        license: "test-fixture",
        evaluationPolicy: .strict,
        fixtures: []
    )
    let manifestURL = try writeManifest(manifest, in: directory)
    return SPEFCorpusRunnerTestCorpus(directory: directory, manifestURL: manifestURL, manifest: manifest)
}

private var diagnosticSPEF: String {
    """
    *SPEF "IEEE 1481-1998"
    *DESIGN "unit"
    *DIVIDER /
    *DELIMITER :
    *BUS_DELIMITER [ ]
    *T_UNIT 1 NS
    *C_UNIT 1 PF
    *R_UNIT 1 OHM

    *PORTS
    OUT O
    IN I

    *D_NET OUT 0.003
    *CONN
    *P OUT O
    *I U1:A I
    *CAP
    1 OUT 0.002
    2 OUT IN 0.001
    *RES
    1 OUT OUT:1 5
    *END
    """
}

private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeManifest(_ manifest: SPEFCorpus.Manifest, in directory: URL) throws -> URL {
    let manifestURL = directory.appending(path: "fixture-manifest.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: manifestURL)
    return manifestURL
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}

private func removeTemporaryItem(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
    }
}
