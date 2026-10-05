import Foundation
import Testing
import PEXCore
import PEXAdapters
import PEXParsers
import PEXPersistence
import PEXRuntime
import PEXTestSupport

@Suite("PEX exact process-profile capture", .timeLimit(.minutes(1)))
struct PEXProcessProfileCaptureTests {
    @Test func cancellationAndCapturedRetryPreserveAliasedRolesAfterHistoryRelocation() async throws {
        try await fixture { request, shared in
            let parsers = PEXParserRegistry(); parsers.register(SPEFPEXParser())
            let registry = PEXAdapterRegistry(adapters: [ProfileCaptureAdapter()])
            let parent = try await PEXOrchestrator(adapterRegistry: registry, parserRegistry: parsers)
                .run(request, cancellationCheck: { true })
            #expect(parent.status == .failed)
            #expect(parent.artifactManifest.corners.first?.failure?.failureKind == .cancelled)
            let root = try #require(request.workingDirectory)
            let base = root.appending(path: "relocated-history")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: parent.manifestURL.deletingLastPathComponent(), to: base.appending(path: parent.runID.description))
            for url in [request.layoutURL, request.sourceNetlistURL, shared] { try FileManager.default.removeItem(at: url) }
            let store = PEXArtifactStore(workspace: .init(baseURL: base, runID: parent.runID))
            let retained = try store.loadResult(), captured = try store.loadRequest()
            let result = try await DefaultPEXEngine(adapterRegistry: registry, parserRegistry: parsers)
                .retryFailedCorners(captured, from: retained)
            #expect(result.status == .success)
            #expect(result.resumedFromRunID == parent.runID)
            #expect(try PEXArtifactStore(workspace: .init(baseURL: base, runID: result.runID)).loadLineage().effectiveStatus == .success)
            let records = result.artifactManifest.artifacts.filter { $0.processProfileInputRole != nil }
            #expect(records.count == 4)
            #expect(Set(records.map(\.relativePath)).count == 1)
            let directory = result.manifestURL.deletingLastPathComponent().appending(path: "inputs/process-profile-decks")
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            #expect(files.count == 1)
            #expect(try files.reduce(0) { $0 + (try Data(contentsOf: $1)).count } == Data("{\"shared\":true}".utf8).count)
        }
    }

    @Test(arguments: ["unchanged", "tampered", "missingBytes", "missingRole", "conflictingRole"])
    func exactLookupAndReloadRespectRoleAndIntegrityBoundaries(change: String) async throws {
        try await fixture { request, _ in
            let result = try await engine().run(request)
            let workspace = PEXRunWorkspace(baseURL: try #require(request.workingDirectory), runID: result.runID)
            let store = PEXArtifactStore(workspace: workspace)
            var manifest = try store.loadManifest()
            var resolver = try PEXArtifactResolver(workspace: workspace, manifest: manifest)
            let view = try resolver.processProfileInputRecord(for: .requiredView("processProfile"))
            #expect(view.matches(kind: .processProfileViewInput))
            if change == "tampered" {
                try Data("{\"shared\":null}".utf8).write(to: resolver.validatedURL(for: view))
            } else if change == "missingBytes" {
                try FileManager.default.removeItem(at: resolver.validatedURL(for: view))
            } else if change == "missingRole" || change == "conflictingRole" {
                let captured = try store.loadRequest()
                let records = try manifest.artifacts.map { record in
                    let role: PEXProcessProfileInputRole?
                    if change == "missingRole", record.processProfileInputRole == .primaryDeck { role = nil }
                    else if change == "conflictingRole", record.processProfileInputRole == .requiredView("secondary") { role = .requiredView("processProfile") }
                    else { return record }
                    return try PEXArtifactRecord(declaration: record.declaration, payload: record.payload,
                        stage: record.stage, cornerID: record.cornerID, createdAt: record.createdAt,
                        provenance: record.provenance, processProfileInputRole: role)
                }
                let inputs = records.filter { $0.stage == .inputValidation || $0.stage == .technologyResolution }
                #expect(try PEXRequestHash.compute(for: captured, inputArtifacts: inputs) != result.requestHash)
                manifest = try PEXArtifactManifest(runID: manifest.runID, requestHash: manifest.requestHash,
                    backendID: manifest.backendID, status: manifest.status, startedAt: manifest.startedAt,
                    finishedAt: manifest.finishedAt, corners: manifest.corners, artifacts: records,
                    warnings: manifest.warnings, extractorRun: manifest.extractorRun,
                    resumedFromRunID: manifest.resumedFromRunID, backendExecutions: manifest.backendExecutions,
                    provenance: manifest.provenance, evidence: manifest.evidence)
                try store.saveManifest(manifest)
                resolver = try PEXArtifactResolver(workspace: workspace, manifest: manifest)
                #expect(try store.loadResult().status == .success)
            }
            if change == "tampered" || change == "missingBytes" {
                // Metadata lookup intentionally does not claim byte integrity.
                #expect(try resolver.processProfileInputRecord(for: .requiredView("processProfile")) == view)
                let report = resolver.completenessReport()
                #expect(report.status == .invalid || report.status == .incomplete)
                let ids = Set(manifest.artifacts.filter { $0.processProfileInputRole != nil }.map { $0.id.rawValue })
                #expect(Set(report.issues.compactMap(\.artifactID)).isSuperset(of: ids))
            }
            if change == "conflictingRole" {
                #expect(throws: PEXError.self) { try resolver.processProfileInputRecord(for: .requiredView("processProfile")) }
            }
            if change == "unchanged" {
                let restored = try store.loadRequest()
                let records = manifest.artifacts.filter { $0.stage == .inputValidation || $0.stage == .technologyResolution }
                #expect(try PEXRequestHash.compute(for: restored, inputArtifacts: records) == result.requestHash)
            } else {
                do { _ = try store.loadRequest(); Issue.record("Invalid profile capture was reconstructed: \(change)") }
                catch let error as PEXError { #expect(error.kind == .persistenceFailed) }
            }
        }
    }

    @Test func recordAndRoleDecodingRejectInvalidAssociations() async throws {
        try await fixture { request, _ in
            let result = try await engine().run(request)
            let deck = try #require(result.artifactManifest.artifacts.first { $0.processProfileInputRole == .primaryDeck })
            #expect(throws: PEXArtifactRecordError.processProfileRoleMismatch) {
                try PEXArtifactRecord(declaration: deck.declaration, payload: deck.payload,
                    stage: deck.stage, processProfileInputRole: .requiredView("processProfile"))
            }
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(deck)) as? [String: Any])
            object["processProfileInputRole"] = ["kind": "requiredView", "identifier": "processProfile"]
            let invalidRecord = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: PEXArtifactRecordError.processProfileRoleMismatch) { try JSONDecoder().decode(PEXArtifactRecord.self, from: invalidRecord) }
            let invalidRole = Data("{\"kind\":\"requiredView\",\"identifier\":\" \"}".utf8)
            #expect(throws: PEXError.self) { try JSONDecoder().decode(PEXProcessProfileInputRole.self, from: invalidRole) }
        }
    }

    private func engine() -> DefaultPEXEngine {
        let parsers = PEXParserRegistry(); parsers.register(SPEFPEXParser())
        return .init(adapterRegistry: .init(adapters: [ProfileCaptureAdapter()]), parserRegistry: parsers)
    }

    private func fixture(_ body: (PEXRunRequest, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pex-profile-role-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Profile role fixture cleanup failed: \(error)") } }
        let layout = root.appending(path: "layout.gds"), netlist = root.appending(path: "source.sp"), shared = root.appending(path: "profile.json")
        try Data("mock layout".utf8).write(to: layout)
        try Data(".subckt TOP\n.ends TOP\n".utf8).write(to: netlist)
        try Data("{\"shared\":true}".utf8).write(to: shared)
        try await body(.init(layoutURL: layout, layoutFormat: .gds, sourceNetlistURL: netlist,
            sourceNetlistFormat: .spice, topCell: "TOP", corners: [.init(id: "tt")],
            technology: .inline(.init(processName: "profile-fixture", stack: [.init(name: "M1", order: 0, material: "metal")],
                logicalToPhysicalLayerMap: [:], vias: [], defaultExtractionRules: .default, backendHints: [:])),
            processProfile: .init(primaryDeckPath: shared.path, cornerDeckPaths: ["tt": shared.path],
                requiredViewPaths: ["processProfile": shared.path, "secondary": shared.path]),
            backendSelection: .mock(), options: .default, workingDirectory: root), shared)
    }
}

/// Captured-input transport fixture; declared mock identities are not physical qualification.
private struct ProfileCaptureAdapter: PEXExtracting, PEXAdapterReadinessProviding {
    private let delegate = MockPEXAdapter()
    var backendID: String { delegate.backendID }
    var capabilities: PEXBackendCapabilities { delegate.capabilities }
    func toolReadiness(processProfile: PEXProcessProfileReference?) -> PEXExtractorToolReadiness { delegate.toolReadiness(processProfile: processProfile) }
    func prepare(_ context: PEXExecutionContext) async throws { try await delegate.prepare(context) }
    func cleanup(_ context: PEXExecutionContext) async { await delegate.cleanup(context) }
    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        let result = try await delegate.execute(context)
        if let check = context.cancellationCheck, try await check() {
            throw PEXAdapterExecutionFailure(message: "Profile capture fixture cancellation", stage: .backendExecution,
                cornerID: context.corner.id, failureKind: .cancelled, generatedArtifacts: result.generatedArtifacts,
                executionIdentity: result.executionIdentity)
        }
        return result
    }
}
