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
        let reference = ArtifactReference(
            id: try ArtifactID(rawValue: "plate:raw-spef"),
            locator: ArtifactLocator(
                location: try ArtifactLocation(workspaceRelativePath: "reports/output.spef"),
                role: .output,
                kind: try ArtifactKind(rawValue: PEXArtifactKind.rawOutput.foundationRawValue),
                format: .spef
            ),
            digest: try ContentDigest(
                algorithm: .sha256,
                hexadecimalValue: String(repeating: "a", count: 64)
            ),
            byteCount: 1
        )
        let artifact = PEXArtifactRecord(
            payload: .available(reference),
            stage: .reporting,
            createdAt: now,
            provenance: nil
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
