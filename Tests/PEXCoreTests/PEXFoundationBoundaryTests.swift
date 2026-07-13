import CircuiteFoundation
import Foundation
import PEXCore
import Testing

@Suite("PEX Foundation boundary")
struct PEXFoundationBoundaryTests {
    @Test
    func preservesDomainArtifactIdentifier() throws {
        let now = Date(timeIntervalSince1970: 1)
        let runID = PEXRunID()
        let artifact = PEXArtifactRecord(
            id: "plate:raw-spef",
            kind: .rawOutput,
            stage: .reporting,
            relativePath: try PEXArtifactPath("reports/output.spef"),
            sha256: String(repeating: "a", count: 64),
            byteCount: 1,
            createdAt: now,
            status: .available
        )
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("request"),
            backendID: "mock",
            status: .success,
            startedAt: now,
            finishedAt: now,
            corners: [],
            artifacts: [artifact],
            warnings: []
        )
        let result = PEXRunResult(
            runID: runID,
            requestHash: PEXRequestHash("request"),
            status: .success,
            startedAt: now,
            finishedAt: now,
            cornerResults: [],
            warnings: [],
            artifacts: manifest,
            manifestURL: URL(fileURLWithPath: "/tmp/pex-manifest.json"),
            metrics: PEXRunMetrics(
                totalDurationSeconds: 0,
                cornerCount: 0,
                successCount: 0,
                failureCount: 0
            )
        )
        let provenance = try ExecutionProvenance(
            producer: ProducerIdentity(
                kind: .engine,
                identifier: "PEXEngine",
                version: "1.0.0"
            ),
            startedAt: now,
            completedAt: now
        )

        let boundary = try PEXFoundationEvidence(
            result: result,
            provenance: provenance
        )

        #expect(boundary.evidence.artifacts.map(\.id.rawValue) == ["plate:raw-spef"])
        #expect(boundary.evidence.artifacts.map(\.locator.role) == [.output])
    }
}
