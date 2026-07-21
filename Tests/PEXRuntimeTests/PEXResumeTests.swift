import Foundation
import Testing
import PEXTestSupport
@testable import PEXCore
@testable import PEXRuntime

@Suite("PEX selective retry contract")
struct PEXResumeTests {
    @Test func retriesOnlyFailedCornersAndRecordsParentRun() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pex-retry-\(UUID().uuidString)")
        defer { remove(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layoutURL = directory.appending(path: "layout.gds")
        let netlistURL = directory.appending(path: "source.sp")
        try Data("mock layout".utf8).write(to: layoutURL)
        try Data(".subckt TOP\n.ends TOP\n".utf8).write(to: netlistURL)

        let request = PEXRunRequest(
            layoutURL: layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TOP",
            corners: [PEXCorner(id: "tt"), PEXCorner(id: "ss")],
            technology: .inline(TechnologyIR(
                processName: "retry-process",
                stack: [TechnologyLayer(name: "M1", order: 0, thickness: 0.1, material: "metal", resistivity: 1.0)],
                logicalToPhysicalLayerMap: [:],
                vias: [],
                defaultExtractionRules: .default,
                backendHints: [:]
            )),
            backendSelection: .mock(),
            options: .default,
            workingDirectory: directory
        )

        let parentID = PEXRunID()
        let now = Date()
        let parentManifest = PEXArtifactManifest(
            runID: parentID,
            requestHash: PEXRequestHash("parent"),
            backendID: "mock",
            status: .partialSuccess,
            startedAt: now,
            finishedAt: now,
            corners: [PEXArtifactCorner(cornerID: "ss", status: .failed, artifactIDs: [])],
            artifacts: [],
            warnings: [],
            provenance: try PEXTestExecutionIdentity.provenance(
                startedAt: now,
                finishedAt: now
            )
        )
        let parentResult = try PEXRunResult(
            runID: parentID,
            requestHash: PEXRequestHash("parent"),
            status: .partialSuccess,
            startedAt: now,
            finishedAt: now,
            cornerResults: [PEXCornerResult(
                cornerID: "ss",
                status: .failed,
                metrics: PEXCornerMetrics(durationSeconds: 0, netCount: 0, elementCount: 0)
            )],
            warnings: [],
            artifactManifest: parentManifest,
            manifestURL: directory.appending(path: "parent-manifest.json"),
            metrics: PEXRunMetrics(totalDurationSeconds: 0, cornerCount: 1, successCount: 0, failureCount: 1)
        )

        let result = try await DefaultPEXEngine.withTestDefaults().retryFailedCorners(
            request,
            from: parentResult
        )

        #expect(result.status == .success)
        #expect(result.cornerResults.map(\.cornerID) == [PEXCornerID("ss")])
        #expect(result.resumedFromRunID == parentID)
        #expect(result.artifactManifest.resumedFromRunID == parentID)
    }

    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // Best-effort cleanup in test teardown.
        }
    }
}
