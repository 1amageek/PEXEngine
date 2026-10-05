import Foundation
import CircuiteFoundation
import Testing
import PEXAdapters
import PEXParsers
import PEXPersistence
import PEXTestSupport
@testable import PEXCore
@testable import PEXRuntime

@Suite("PEX selective retry contract", .timeLimit(.minutes(1)))
struct PEXResumeTests {
    @Test(arguments: [false, true])
    func retriesOnlyFailedCornersAndRecordsParentRun(subset: Bool) async throws {
        try await fixture { request in
            let parent = try await engine(failCorner: "ss").run(request)
            #expect(parent.status == .partialSuccess)
            let store = PEXArtifactStore(workspace: .init(baseURL: try #require(request.workingDirectory), runID: parent.runID))
            let captured = try store.loadRequest()
            let retryRequest = replacing(captured, corners: subset ? [.init(id: "ss")] : captured.corners)
            let result = try await engine().retryFailedCorners(retryRequest, from: parent)
            #expect(result.status == .success)
            #expect(result.cornerResults.map(\.cornerID) == [PEXCornerID("ss")])
            #expect(result.resumedFromRunID == parent.runID)
            #expect(result.artifactManifest.resumedFromRunID == parent.runID)
            #expect(result.requestHash != parent.requestHash)
            let lineage = try PEXArtifactStore(workspace: .init(baseURL: try #require(request.workingDirectory), runID: result.runID)).loadLineage()
            #expect(lineage.effectiveStatus == .success)
            #expect(lineage.effectiveCornerResults.map(\.cornerID) == [PEXCornerID("ss"), PEXCornerID("tt")])
        }
    }

    @Test func changedMeasuredImplementationCannotJoinParent() async throws {
        try await fixture { request in
            let parent = try await engine(failCorner: "ss").run(request)
            let captured = try PEXArtifactStore(workspace: .init(baseURL: try #require(request.workingDirectory), runID: parent.runID)).loadRequest()
            do {
                _ = try await engine(identityVersion: "different-image").retryFailedCorners(captured, from: parent)
                Issue.record("A changed implementation joined the retained parent")
            } catch let error as PEXError {
                #expect(error.kind == .backendExecutionFailed)
            }
        }
    }

    @Test func changedSelectedCornerPVTIsRejected() async throws {
        try await fixture { request in
            let parent = try await engine(failCorner: "ss").run(request)
            let captured = try PEXArtifactStore(workspace: .init(baseURL: try #require(request.workingDirectory), runID: parent.runID)).loadRequest()
            do {
                _ = try await engine().retryFailedCorners(replacing(captured, corners: [.init(id: "ss", name: "ss", temperature: 50)]), from: parent)
                Issue.record("Changed retry PVT was accepted")
            } catch let error as PEXError {
                #expect(error.kind == .invalidInput)
            }
        }
    }

    @Test(arguments: [false, true])
    func publicOrchestratorParentEntryRequiresCapturedMeaning(changed: Bool) async throws {
        try await fixture { request in
            let parent = try await engine(failCorner: "ss").run(request)
            let captured = try PEXArtifactStore(workspace: .init(baseURL: try #require(request.workingDirectory), runID: parent.runID)).loadRequest()
            let retryRequest = PEXRunRequest(layoutURL: captured.layoutURL, layoutFormat: captured.layoutFormat,
                sourceNetlistURL: captured.sourceNetlistURL, sourceNetlistFormat: captured.sourceNetlistFormat,
                topCell: changed ? "DIFFERENT_TOP" : captured.topCell, corners: [.init(id: "ss")],
                technology: captured.technology, technologyByCorner: captured.technologyByCorner,
                nativeInput: captured.nativeInput, processProfile: captured.processProfile,
                backendSelection: captured.backendSelection, options: captured.options,
                workingDirectory: captured.workingDirectory, executionInputArtifacts: captured.executionInputArtifacts)
            let parsers = PEXParserRegistry(); parsers.register(SPEFPEXParser())
            let orchestrator = PEXOrchestrator(adapterRegistry: .init(adapters: [RetryContractAdapter(failCorner: nil, identityVersion: nil)]), parserRegistry: parsers)
            do {
                let result = try await orchestrator.run(retryRequest, cancellationCheck: nil, resumedFromRunID: parent.runID)
                #expect(!changed)
                #expect(result.status == .success && result.resumedFromRunID == parent.runID)
            } catch let error as PEXError {
                #expect(changed && error.kind == .invalidInput)
            }
        }
    }

    @Test(arguments: [false, true])
    func inputRelocationPreservesMeaningButChildBaseMustRetainParent(changeBase: Bool) async throws {
        try await fixture { request in
            let root = try #require(request.workingDirectory)
            let parent = try await engine(failCorner: "ss").run(request)
            let captured = try PEXArtifactStore(workspace: .init(baseURL: root, runID: parent.runID)).loadRequest()
            let relocated = root.appending(path: "relocated")
            try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: true)
            let layout = relocated.appending(path: "layout-copy.gds"), netlist = relocated.appending(path: "netlist-copy.sp")
            try FileManager.default.copyItem(at: captured.layoutURL, to: layout)
            try FileManager.default.copyItem(at: captured.sourceNetlistURL, to: netlist)
            let retryRequest = PEXRunRequest(layoutURL: layout, layoutFormat: captured.layoutFormat,
                sourceNetlistURL: netlist, sourceNetlistFormat: captured.sourceNetlistFormat,
                topCell: captured.topCell, corners: [.init(id: "ss")], technology: captured.technology,
                technologyByCorner: captured.technologyByCorner, nativeInput: captured.nativeInput,
                processProfile: captured.processProfile, backendSelection: captured.backendSelection,
                options: captured.options, workingDirectory: changeBase ? relocated : root,
                executionInputArtifacts: captured.executionInputArtifacts)
            do {
                let result = try await engine().retryFailedCorners(retryRequest, from: parent)
                #expect(!changeBase && result.status == .success)
            } catch let error as PEXError {
                #expect(changeBase && error.kind == .invalidInput)
            }
        }
    }

    private func replacing(_ request: PEXRunRequest, corners: [PEXCorner]) -> PEXRunRequest {
        .init(layoutURL: request.layoutURL, layoutFormat: request.layoutFormat,
            sourceNetlistURL: request.sourceNetlistURL, sourceNetlistFormat: request.sourceNetlistFormat,
            topCell: request.topCell, corners: corners, technology: request.technology,
            technologyByCorner: request.technologyByCorner, nativeInput: request.nativeInput,
            processProfile: request.processProfile, backendSelection: request.backendSelection,
            options: request.options, workingDirectory: request.workingDirectory,
            executionInputArtifacts: request.executionInputArtifacts)
    }

    private func engine(failCorner: PEXCornerID? = nil, identityVersion: String? = nil) -> DefaultPEXEngine {
        let parsers = PEXParserRegistry(); parsers.register(SPEFPEXParser())
        return .init(adapterRegistry: .init(adapters: [RetryContractAdapter(failCorner: failCorner, identityVersion: identityVersion)]), parserRegistry: parsers)
    }

    private func fixture(_ body: (PEXRunRequest) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pex-retry-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { Issue.record("Retry fixture cleanup failed: \(error)") } }
        let layoutURL = directory.appending(path: "layout.gds"), netlistURL = directory.appending(path: "source.sp")
        try Data("mock layout".utf8).write(to: layoutURL)
        try Data(".subckt TOP\n.ends TOP\n".utf8).write(to: netlistURL)
        try await body(.init(layoutURL: layoutURL, layoutFormat: .gds, sourceNetlistURL: netlistURL,
            sourceNetlistFormat: .spice, topCell: "TOP", corners: [.init(id: "tt"), .init(id: "ss")],
            technology: .inline(.init(processName: "retry-process", stack: [.init(name: "M1", order: 0, material: "metal")],
                logicalToPhysicalLayerMap: [:], vias: [], defaultExtractionRules: .default, backendHints: [:])),
            backendSelection: .mock(), options: .default, workingDirectory: directory))
    }
}

/// Public-runtime contract fixture; its declared image is not native image qualification.
private struct RetryContractAdapter: PEXExtracting, PEXAdapterReadinessProviding {
    let failCorner: PEXCornerID?
    let identityVersion: String?
    private let delegate = MockPEXAdapter()
    var backendID: String { delegate.backendID }
    var capabilities: PEXBackendCapabilities { delegate.capabilities }
    func toolReadiness(processProfile: PEXProcessProfileReference?) -> PEXExtractorToolReadiness { delegate.toolReadiness(processProfile: processProfile) }
    func prepare(_ context: PEXExecutionContext) async throws { try await delegate.prepare(context) }
    func cleanup(_ context: PEXExecutionContext) async { await delegate.cleanup(context) }
    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        let result = try await delegate.execute(context)
        let identity = try identityVersion.map { try PEXTestExecutionIdentity.make(backendID: backendID, version: $0) } ?? result.executionIdentity
        if context.corner.id == failCorner {
            throw PEXAdapterExecutionFailure(message: "Selective retry fixture failure", stage: .backendExecution,
                cornerID: context.corner.id, failureKind: .backendExecutionFailed,
                generatedArtifacts: result.generatedArtifacts, executionIdentity: identity)
        }
        return try .init(output: result.output, generatedArtifacts: result.generatedArtifacts, executionIdentity: identity)
    }
}
