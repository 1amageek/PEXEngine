import CircuiteFoundation
import CircuiteFoundationFoundation
import Foundation
import PEXCore
import PEXTestSupport
import Testing

@Suite("PEX Foundation boundary")
struct PEXFoundationBoundaryTests {
    @Test
    func preservesDomainArtifactIdentifier() throws {
        let now = Date(timeIntervalSince1970: 1)
        let runID = PEXRunID()
        let descriptor = ArtifactDescriptor(
            role: .output,
            kind: try ArtifactKind(rawValue: PEXArtifactKind.rawOutput.foundationRawValue),
            format: .spef
        )
        let relativePath = try ArtifactRelativePath(segments: ["reports", "output.spef"])
        let reference = try ArtifactReference(
            digest: try ContentDigest(
                algorithm: .sha256,
                hexadecimalValue: String(repeating: "a", count: 64)
            ),
            byteCount: 1,
            descriptor: descriptor
        )
        let artifact = try PEXArtifactRecord(
            declaration: PEXArtifactDeclaration(
                id: try PEXArtifactRecordID(rawValue: "plate:raw-spef"),
                descriptor: descriptor,
                relativePath: relativePath
            ),
            payload: .available(try PEXAvailableArtifact(
                reference: reference,
                availability: .local(
                    artifactID: reference.id,
                    rootID: try ArtifactRootID(rawValue: "pex-test-run"),
                    relativePath: relativePath
                )
            )),
            stage: .reporting,
            createdAt: now,
            provenance: nil
        )
        let manifest = try PEXTestExecutionIdentity.manifest(
            runID: runID,
            requestHash: PEXRequestHash("request"),
            backendID: "mock",
            status: .success,
            startedAt: now,
            finishedAt: now,
            corners: [],
            artifacts: [artifact],
            warnings: [],
            provenance: try PEXTestExecutionIdentity.provenance(
                startedAt: now,
                finishedAt: now
            )
        )
        let result = try PEXRunResult(
            runID: runID,
            requestHash: PEXRequestHash("request"),
            status: .success,
            startedAt: now,
            finishedAt: now,
            cornerResults: [],
            warnings: [],
            artifactManifest: manifest,
            manifestURL: URL(fileURLWithPath: "/tmp/pex-manifest.json"),
            metrics: PEXRunMetrics(
                totalDurationSeconds: 0,
                cornerCount: 0,
                successCount: 0,
                failureCount: 0
            )
        )
        #expect(artifact.id.rawValue == "plate:raw-spef")
        #expect(result.evidence.artifacts.map(\.id) == [reference.id])
        #expect(result.evidence.artifacts.map(\.descriptor.role) == [.output])
        #expect(throws: PEXArtifactManifestError.evidenceArtifactsMismatch) {
            _ = try PEXArtifactManifest(
                runID: runID,
                requestHash: PEXRequestHash("request"),
                backendID: "mock",
                status: .success,
                startedAt: now,
                finishedAt: now,
                corners: [],
                artifacts: [artifact],
                warnings: [],
                provenance: manifest.provenance,
                evidence: EvidenceManifest(
                    id: manifest.evidence.id,
                    provenance: manifest.provenance,
                    artifacts: []
                )
            )
        }
    }
}
