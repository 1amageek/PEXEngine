import Foundation
import PEXTestSupport
import Testing
@testable import PEXCore
@testable import PEXPersistence

@Suite("PEX run lineage tests")
struct PEXLineageTests {
    @Test(arguments: ["unchanged", "model", "implementation", "successfulCorner", "missingRequest"])
    func loadLineageRequiresCompatibleRetainedRequests(change: String) throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appending(path: "pex-lineage-\(UUID().uuidString)")
        defer { remove(baseURL) }

        let parentID = PEXRunID()
        let parentWorkspace = PEXRunWorkspace(baseURL: baseURL, runID: parentID)
        try parentWorkspace.createDirectories(corners: ["tt", "ss"])
        let parentStore = PEXArtifactStore(workspace: parentWorkspace)
        let parentRecorder = PEXArtifactRecorder(workspace: parentWorkspace)
        let executionIdentity = try PEXTestExecutionIdentity.make(backendID: "mock")
        let parentInputs = try captureRequest(corners: ["tt", "ss"], process: "lineage", workspace: parentWorkspace)
        let parentHash = try PEXRequestHash.compute(for: parentInputs.request, inputArtifacts: parentInputs.records)
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
        try parentStore.saveManifest(PEXTestExecutionIdentity.manifest(
            runID: parentID,
            requestHash: parentHash,
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
            artifacts: parentInputs.records + [parentIRRecord, parentLogRecord],
            warnings: [],
            backendExecutions: [executionIdentity],
            provenance: parentProvenance
        ))

        let childID = PEXRunID()
        let childWorkspace = PEXRunWorkspace(baseURL: baseURL, runID: childID)
        try childWorkspace.createDirectories(corners: ["ss"])
        let childStore = PEXArtifactStore(workspace: childWorkspace)
        let childRecorder = PEXArtifactRecorder(workspace: childWorkspace)
        let childCorner: PEXCornerID = change == "successfulCorner" ? "tt" : "ss"
        let childInputs = try captureRequest(corners: [childCorner], process: change == "model" ? "different-model" : "lineage", workspace: childWorkspace)
        let childHash = try PEXRequestHash.compute(for: childInputs.request, inputArtifacts: childInputs.records)
        let childIdentity = change == "implementation" ? try PEXTestExecutionIdentity.make(backendID: "mock", version: "different-image") : executionIdentity
        let childProvenance = try PEXTestExecutionIdentity.provenance(
            startedAt: Date(timeIntervalSince1970: 3),
            finishedAt: Date(timeIntervalSince1970: 4)
        )
        try childStore.saveIR(makeIR(cornerID: childCorner.value), for: childCorner)
        let childIRRecord = try childRecorder.recordExistingArtifact(
            url: childWorkspace.cornerIRURL(childCorner),
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: childCorner,
            id: "ir-child-ss",
            producer: executionIdentity.producer
        )
        try childStore.saveManifest(PEXTestExecutionIdentity.manifest(
            runID: childID,
            requestHash: childHash,
            backendID: "mock",
            status: .success,
            startedAt: Date(timeIntervalSince1970: 3),
            finishedAt: Date(timeIntervalSince1970: 4),
            corners: [PEXArtifactCorner(cornerID: childCorner, status: .success, artifactIDs: [childIRRecord.id])],
            artifacts: childInputs.records + [childIRRecord],
            warnings: [],
            resumedFromRunID: parentID,
            backendExecutions: [childIdentity],
            provenance: childProvenance
        ))

        if change == "missingRequest" {
            try FileManager.default.removeItem(at: parentWorkspace.requestURL)
        }
        if change != "unchanged" {
            do {
                _ = try childStore.loadLineage()
                Issue.record("Incompatible retained lineage was accepted: \(change)")
            } catch let error as PEXError {
                #expect(error.kind == .persistenceFailed)
            }
            // Historical results remain inspectable without granting aggregate compatibility.
            #expect(try childStore.loadResult().status == .success)
            return
        }
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

    private func captureRequest(corners: [PEXCornerID], process: String, workspace: PEXRunWorkspace)
        throws -> (request: PEXRunRequest, records: [PEXArtifactRecord]) {
        let layout = workspace.runDirectory.appending(path: "source-layout.gds")
        let netlist = workspace.runDirectory.appending(path: "source-netlist.sp")
        try Data("lineage-layout".utf8).write(to: layout)
        try Data(".subckt TOP\n.ends TOP\n".utf8).write(to: netlist)
        let technology = TechnologyIR(processName: process, stack: [], logicalToPhysicalLayerMap: [:],
            vias: [], defaultExtractionRules: .default, backendHints: [:])
        let request = PEXRunRequest(layoutURL: layout, layoutFormat: .gds, sourceNetlistURL: netlist,
            sourceNetlistFormat: .spice, topCell: "TOP", corners: corners.map { .init(id: $0, name: $0.value) },
            technology: .inline(technology), backendSelection: .mock(), options: .default,
            workingDirectory: workspace.baseURL)
        let recorder = PEXArtifactRecorder(workspace: workspace)
        let inputs = [try recorder.captureInput(url: layout, kind: .layoutInput),
            try recorder.captureInput(url: netlist, kind: .netlistInput),
            try recorder.captureInlineTechnology(technology)]
        let captured = try recorder.capturedRequest(request, inputArtifacts: inputs)
        let requestRecord = try recorder.captureRunRequest(request, inputArtifacts: inputs)
        return (captured, inputs + [requestRecord.artifact])
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
