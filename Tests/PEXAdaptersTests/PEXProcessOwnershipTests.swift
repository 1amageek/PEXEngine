import Foundation
import Testing
import PEXCore
import PEXRuntime
import SignoffToolSupport
@testable import PEXAdapters

@Suite("PEX live process cleanup ownership", .timeLimit(.minutes(1)))
struct PEXProcessOwnershipTests {
    @Test func pendingCleanupSurvivesEveryCornerUntilCallerClosesIt() async throws {
        let processFailure: TimedProcessFailure
        do {
            _ = try await TimedProcessRunner(timeoutSeconds: 0.02, terminationGraceSeconds: 0,
                maximumOutputByteCount: 1, cleanupTimeoutSeconds: 0.000000001)
                .run(executableURL: URL(filePath: "/bin/sh"), arguments: ["-c", "trap '' TERM; for i in 1 2 3 4; do (trap '' TERM; while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'; done) & done; wait"])
            Issue.record("Expected process timeout"); return
        } catch let error as TimedProcessError {
            guard case .executionFailed(let failure) = error else { throw error }
            processFailure = failure
        }
        let handle = try #require(processFailure.cleanupHandle)
        let pending = PEXProcessCleanupFailure(processFailure: processFailure, retryFailure: "Owned pending-close fixture")
        let root = FileManager.default.temporaryDirectory.appending(path: "pex-cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Cleanup: \(error)") } }
        do {
            let layout = root.appending(path: "input.gds"), source = root.appending(path: "source.cir")
            try Data([1]).write(to: layout)
            try Data(".subckt TOP A\n.ends TOP\n".utf8).write(to: source)
            let request = PEXRunRequest(layoutURL: layout, layoutFormat: .gds, sourceNetlistURL: source,
                sourceNetlistFormat: .spice, topCell: "TOP", corners: [.init(id: "tt"), .init(id: "ss")],
                technology: .inline(.init(processName: "fixture", stack: [], logicalToPhysicalLayerMap: [:],
                    vias: [], defaultExtractionRules: .default, backendHints: [:])),
                backendSelection: .init(backendID: "cleanup-fixture"), options: .default, workingDirectory: root)
            let engine = DefaultPEXEngine(adapterRegistry: .init(adapters: [PendingCleanupAdapter(pending: pending)]), parserRegistry: .init())
            do { _ = try await engine.run(request); Issue.record("Pending ownership must not become a returned run result") }
            catch let error as PEXOrchestrator.PendingCleanupFailure {
                #expect(error.failures.count == 2)
                #expect(error.failures.allSatisfy { $0.processFailure.cleanupHandle == handle })
                #expect(error.failures.allSatisfy { $0.processFailure.cause == processFailure.cause })
            }
        } catch {
            do { try await handle.close(timeoutSeconds: 5) }
            catch let closeError { throw PEXProcessCleanupFailure(processFailure: processFailure, retryFailure: String(describing: closeError)) }
            throw error
        }
        try await handle.close(timeoutSeconds: 5)
        try await handle.close(timeoutSeconds: 0.1)
    }
}

private struct PendingCleanupAdapter: PEXExtracting {
    let pending: PEXProcessCleanupFailure
    let backendID = "cleanup-fixture"
    let capabilities = PEXBackendCapabilities(supportsCouplingCaps: true, supportsCornerSweep: true,
        supportsIncremental: false, supportsRCReduction: false, nativeOutputFormats: [])
    func prepare(_ context: PEXExecutionContext) async throws {}
    func cleanup(_ context: PEXExecutionContext) async {}
    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        throw PEXAdapterExecutionFailure(message: "Pending cleanup", stage: .backendExecution,
            cornerID: context.corner.id, failureKind: .backendExecutionFailed, underlying: pending)
    }
}
