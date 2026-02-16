import Testing
import Foundation
@testable import PEXCore
@testable import PEXPersistence

@Suite("PEXPersistence Tests")
struct PEXPersistenceTests {
    @Test func workspaceDirectoryLayout() {
        let runID = PEXRunID()
        let base = FileManager.default.temporaryDirectory
        let workspace = PEXRunWorkspace(baseURL: base, runID: runID)

        #expect(workspace.runDirectory.path(percentEncoded: false).contains(runID.description))
        #expect(workspace.manifestURL.lastPathComponent == "manifest.json")
        #expect(workspace.requestURL.lastPathComponent == "request.json")

        let cornerDir = workspace.cornerRawDirectory(PEXCornerID("tt"))
        #expect(cornerDir.path(percentEncoded: false).contains("raw/tt"))
    }

    @Test func irSerializerRoundTrip() throws {
        let serializer = PEXIRSerializer()
        let ir = makeTestIR()
        let data = try serializer.encode(ir)
        let decoded = try serializer.decode(from: data)
        #expect(decoded.nets.count == ir.nets.count)
        #expect(decoded.elements.count == ir.elements.count)
        #expect(decoded.cornerID == ir.cornerID)
    }

    @Test func manifestCodable() throws {
        let manifest = PEXManifest(
            runID: PEXRunID(),
            requestHash: PEXRequestHash("abc123"),
            backendID: "mock",
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [
                PEXManifest.CornerEntry(
                    cornerID: "tt", status: .success,
                    rawFiles: ["tt.spef"], irFile: "tt.json", logFile: nil
                )
            ],
            warnings: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PEXManifest.self, from: data)
        #expect(decoded.runID == manifest.runID)
        #expect(decoded.status == .success)
        #expect(decoded.corners.count == 1)
    }

    @Test func reportGeneration() {
        let result = makeTestResult()
        let generator = PEXReportGenerator()
        let report = generator.generateSummary(result: result)
        #expect(report.contains("PEX Extraction Summary"))
        #expect(report.contains("success"))
    }

    @Test func artifactStoreSaveLoadRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_persist_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        let cornerID: PEXCornerID = "tt"
        try workspace.createDirectories(corners: [cornerID])

        let store = PEXArtifactStore(workspace: workspace)

        let ir = makeTestIR()
        try store.saveIR(ir, for: cornerID)

        let manifest = PEXManifest(
            runID: runID,
            requestHash: PEXRequestHash("roundtrip"),
            backendID: "mock",
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [
                PEXManifest.CornerEntry(
                    cornerID: "tt", status: .success,
                    rawFiles: ["tt.spef"], irFile: "tt.json", logFile: nil
                )
            ],
            warnings: ["test warning"]
        )
        try store.saveManifest(manifest)

        let result = try store.loadResult(cornerIDs: [cornerID])
        #expect(result.runID == runID)
        #expect(result.status == .success)
        #expect(result.cornerResults.count == 1)
        #expect(result.cornerResults[0].ir != nil)
        #expect(result.cornerResults[0].ir?.nets.count == 1)
        #expect(result.metrics.successCount == 1)
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message == "test warning")
    }

    @Test func loadResultMultiCorner() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_multi_persist_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runID = PEXRunID()
        let corners: [PEXCornerID] = ["tt", "ss", "ff"]
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: corners)

        let store = PEXArtifactStore(workspace: workspace)

        for corner in corners {
            let ir = ParasiticIR(
                version: "1.0", cornerID: corner, units: .canonical,
                nets: [ParasiticNet(name: NetName("net_\(corner.value)"), nodes: [], totalGroundCapF: 1e-12, totalCouplingCapF: 0, totalResistanceOhm: 10)],
                elements: [], metadata: [:]
            )
            try store.saveIR(ir, for: corner)
        }

        let manifest = PEXManifest(
            runID: runID,
            requestHash: PEXRequestHash("multi"),
            backendID: "mock",
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: corners.map { PEXManifest.CornerEntry(cornerID: $0, status: .success, rawFiles: [], irFile: "\($0.value).json", logFile: nil) },
            warnings: []
        )
        try store.saveManifest(manifest)

        let result = try store.loadResult(cornerIDs: corners, manifest: manifest)
        #expect(result.cornerResults.count == 3)
        #expect(result.metrics.cornerCount == 3)
        #expect(result.metrics.successCount == 3)
        #expect(result.metrics.failureCount == 0)

        for cr in result.cornerResults {
            #expect(cr.ir != nil)
            #expect(cr.status == .success)
            #expect(cr.ir?.nets.count == 1)
        }
    }

    @Test func loadResultWithFailedCorner() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_fail_persist_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runID = PEXRunID()
        let successCorner: PEXCornerID = "tt"
        let failCorner: PEXCornerID = "ss"
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: [successCorner, failCorner])

        let store = PEXArtifactStore(workspace: workspace)

        let ir = makeTestIR()
        try store.saveIR(ir, for: successCorner)

        // Save IR for fail corner too (loadResult needs it)
        let failIR = ParasiticIR(
            version: "1.0", cornerID: failCorner, units: .canonical,
            nets: [], elements: [], metadata: [:]
        )
        try store.saveIR(failIR, for: failCorner)

        let manifest = PEXManifest(
            runID: runID,
            requestHash: PEXRequestHash("partial"),
            backendID: "mock",
            status: .partialSuccess,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [
                PEXManifest.CornerEntry(cornerID: "tt", status: .success, rawFiles: [], irFile: "tt.json", logFile: nil),
                PEXManifest.CornerEntry(cornerID: "ss", status: .failed, rawFiles: [], irFile: nil, logFile: nil),
            ],
            warnings: ["corner ss failed"]
        )
        try store.saveManifest(manifest)

        let result = try store.loadResult(cornerIDs: [successCorner, failCorner], manifest: manifest)
        #expect(result.status == .partialSuccess)
        #expect(result.cornerResults.count == 2)

        let ttResult = result.cornerResults.first { $0.cornerID == successCorner }
        let ssResult = result.cornerResults.first { $0.cornerID == failCorner }
        #expect(ttResult?.status == .success)
        #expect(ssResult?.status == .failed)
    }

    @Test func loadManifestRejectsMissingFile() {
        let workspace = PEXRunWorkspace(
            baseURL: URL(filePath: "/nonexistent/workspace"),
            runID: PEXRunID()
        )
        let store = PEXArtifactStore(workspace: workspace)
        do {
            _ = try store.loadManifest()
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .persistenceFailed)
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test func loadIRRejectsMissingFile() {
        let workspace = PEXRunWorkspace(
            baseURL: URL(filePath: "/nonexistent/workspace"),
            runID: PEXRunID()
        )
        let store = PEXArtifactStore(workspace: workspace)
        do {
            _ = try store.loadIR(for: PEXCornerID("tt"))
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .persistenceFailed)
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test func reportGeneratorTopNetsAndWarnings() {
        let ir = ParasiticIR(
            version: "1.0", cornerID: "tt", units: .canonical,
            nets: [
                ParasiticNet(name: NetName("VDD"), nodes: [], totalGroundCapF: 1e-12, totalCouplingCapF: 5e-13, totalResistanceOhm: 100),
                ParasiticNet(name: NetName("GND"), nodes: [], totalGroundCapF: 2e-12, totalCouplingCapF: 0, totalResistanceOhm: 50),
            ],
            elements: [], metadata: [:]
        )
        let result = PEXRunResult(
            runID: PEXRunID(),
            requestHash: PEXRequestHash("h"),
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            cornerResults: [
                PEXCornerResult(
                    cornerID: "tt", status: .success, ir: ir,
                    metrics: PEXCornerMetrics(durationSeconds: 0.5, netCount: 2, elementCount: 0)
                )
            ],
            warnings: [PEXWarning(stage: .irValidation, cornerID: "tt", message: "test warning")],
            artifacts: PEXArtifactIndex(manifestURL: URL(filePath: "/tmp/m.json"), requestURL: URL(filePath: "/tmp/r.json"), cornerArtifacts: [:]),
            metrics: PEXRunMetrics(totalDurationSeconds: 0.5, cornerCount: 1, successCount: 1, failureCount: 0)
        )
        let generator = PEXReportGenerator()
        let report = generator.generateSummary(result: result)
        #expect(report.contains("VDD"))
        #expect(report.contains("GND"))
        #expect(report.contains("Top Nets"))
        #expect(report.contains("test warning"))
        #expect(report.contains("Warnings"))
    }

    private func makeTestIR() -> ParasiticIR {
        ParasiticIR(
            version: "1.0", cornerID: "tt", units: .canonical,
            nets: [ParasiticNet(name: NetName("n"), nodes: [], totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0)],
            elements: [], metadata: [:]
        )
    }

    private func makeTestResult() -> PEXRunResult {
        PEXRunResult(
            runID: PEXRunID(),
            requestHash: PEXRequestHash("hash"),
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            cornerResults: [
                PEXCornerResult(
                    cornerID: "tt", status: .success, ir: makeTestIR(),
                    rawOutputURLs: [], logURL: nil,
                    metrics: PEXCornerMetrics(durationSeconds: 1.0, netCount: 1, elementCount: 0, peakMemoryBytes: nil)
                )
            ],
            warnings: [],
            artifacts: PEXArtifactIndex(
                manifestURL: URL(filePath: "/tmp/manifest.json"),
                requestURL: URL(filePath: "/tmp/request.json"),
                cornerArtifacts: [:],
                reportURL: nil
            ),
            metrics: PEXRunMetrics(totalDurationSeconds: 1.0, cornerCount: 1, successCount: 1, failureCount: 0)
        )
    }
}
