import Foundation
import PEXTestSupport
import Testing
@testable import PEXCore
@testable import PEXPersistence

@Suite("PEX run lineage tests")
struct PEXLineageTests {
    @Test func loadLineageMergesParentSuccessWithRetriedCorner() throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appending(path: "pex-lineage-\(UUID().uuidString)")
        defer { remove(baseURL) }

        let parentID = PEXRunID()
        let parentWorkspace = PEXRunWorkspace(baseURL: baseURL, runID: parentID)
        try parentWorkspace.createDirectories(corners: ["tt", "ss"])
        let parentStore = PEXArtifactStore(workspace: parentWorkspace)
        let parentRecorder = PEXArtifactRecorder(workspace: parentWorkspace)
        let executionIdentity = try PEXTestExecutionIdentity.make(backendID: "mock")
        let parentProvenance = try PEXTestExecutionIdentity.provenance(
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2)
        )
        try parentStore.saveIR(makeIR(cornerID: "tt"), for: "tt")
        let parentIRRecord = try parentRecorder.recordExistingArtifact(
            url: parentWorkspace.cornerIRURL("tt"),
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: "tt",
            id: "ir-parent-tt",
            producer: executionIdentity.producer
        )
        let parentLogURL = parentWorkspace.cornerLogURL("ss")
        try Data("backend failed".utf8).write(to: parentLogURL)
        let parentLogRecord = try parentRecorder.recordExistingArtifact(
            url: parentLogURL,
            kind: .log,
            stage: .backendExecution,
            cornerID: "ss",
            id: "log-parent-ss",
            producer: executionIdentity.producer
        )
        try parentStore.saveManifest(PEXArtifactManifest(
            runID: parentID,
            requestHash: PEXRequestHash("parent"),
            backendID: "mock",
            status: .partialSuccess,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            corners: [
                PEXArtifactCorner(cornerID: "tt", status: .success, artifactIDs: [parentIRRecord.id]),
                PEXArtifactCorner(
                    cornerID: "ss",
                    status: .failed,
                    artifactIDs: [parentLogRecord.id],
                    failure: PEXArtifactFailure(stage: .backendExecution, message: "backend failed")
                ),
            ],
            artifacts: [parentIRRecord, parentLogRecord],
            warnings: [],
            backendExecutions: [executionIdentity],
            provenance: parentProvenance
        ))

        let childID = PEXRunID()
        let childWorkspace = PEXRunWorkspace(baseURL: baseURL, runID: childID)
        try childWorkspace.createDirectories(corners: ["ss"])
        let childStore = PEXArtifactStore(workspace: childWorkspace)
        let childRecorder = PEXArtifactRecorder(workspace: childWorkspace)
        let childProvenance = try PEXTestExecutionIdentity.provenance(
            startedAt: Date(timeIntervalSince1970: 3),
            finishedAt: Date(timeIntervalSince1970: 4)
        )
        try childStore.saveIR(makeIR(cornerID: "ss"), for: "ss")
        let childIRRecord = try childRecorder.recordExistingArtifact(
            url: childWorkspace.cornerIRURL("ss"),
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: "ss",
            id: "ir-child-ss",
            producer: executionIdentity.producer
        )
        try childStore.saveManifest(PEXArtifactManifest(
            runID: childID,
            requestHash: PEXRequestHash("child"),
            backendID: "mock",
            status: .success,
            startedAt: Date(timeIntervalSince1970: 3),
            finishedAt: Date(timeIntervalSince1970: 4),
            corners: [PEXArtifactCorner(cornerID: "ss", status: .success, artifactIDs: [childIRRecord.id])],
            artifacts: [childIRRecord],
            warnings: [],
            resumedFromRunID: parentID,
            backendExecutions: [executionIdentity],
            provenance: childProvenance
        ))

        let lineage = try childStore.loadLineage()
        #expect(lineage.rootRunID == parentID)
        #expect(lineage.leafRunID == childID)
        #expect(lineage.runs.map(\.runID) == [parentID, childID])
        #expect(lineage.effectiveStatus == .success)
        #expect(lineage.effectiveCornerResults.map(\.cornerID) == [PEXCornerID("ss"), PEXCornerID("tt")])
        #expect(lineage.effectiveCornerResults.first { $0.cornerID == "ss" }?.status == .success)
        #expect(lineage.effectiveCornerResults.first { $0.cornerID == "tt" }?.status == .success)
        #expect(lineage.effectiveCorners.first { $0.cornerID == "ss" }?.sourceRunID == childID)
        #expect(lineage.effectiveCorners.first { $0.cornerID == "ss" }?.artifactIDs == [childIRRecord.id.rawValue])
        #expect(lineage.effectiveCorners.first { $0.cornerID == "tt" }?.sourceRunID == parentID)
        #expect(lineage.effectiveCorners.first { $0.cornerID == "tt" }?.artifactIDs == [parentIRRecord.id.rawValue])

        let encoded = try JSONEncoder().encode(lineage)
        var incompleteObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        incompleteObject.removeValue(forKey: "effectiveCorners")
        let incompleteData = try JSONSerialization.data(withJSONObject: incompleteObject)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PEXRunLineage.self, from: incompleteData)
        }
    }

    private func makeIR(cornerID: String) -> ParasiticIR {
        ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: PEXCornerID(cornerID),
            units: .canonical,
            nets: [],
            elements: [],
            metadata: [:]
        )
    }

    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Failed to remove temporary lineage workspace: \(error)")
        }
    }
}
