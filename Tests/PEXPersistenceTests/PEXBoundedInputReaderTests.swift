import Foundation
import Darwin
import Testing
import PEXCore
import PEXPersistence

@Suite("Bounded native file read", .timeLimit(.minutes(1)))
struct PEXBoundedInputReaderTests {
    @Test func readsMultipleChunksAndRejectsExcessMissingAndDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bounded-native-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let file = root.appending(path: "input.bin"), data = Data(repeating: 37, count: 600_000)
        try data.write(to: file)
        #expect(try PEXBoundedInputReader().read(file, maximumBytes: data.count) == data)
        #expect(throws: PEXError.self) { try PEXBoundedInputReader().read(file, maximumBytes: data.count - 1) }
        #expect(throws: PEXError.self) { try PEXBoundedInputReader().read(file, maximumBytes: 0) }
        #expect(throws: PEXError.self) { try PEXBoundedInputReader().read(root, maximumBytes: 10) }
        #expect(throws: PEXError.self) { try PEXBoundedInputReader().read(root.appending(path: "missing"), maximumBytes: 10) }
    }
    @Test func captureRefusesFIFOAndByteExcessBeforeMaterialization() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bounded-capture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Cleanup failed: \(error)") } }
        let fifo = root.appending(path: "pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let workspace = PEXRunWorkspace(baseURL: root, runID: PEXRunID())
        try workspace.createDirectories(corners: [])
        let recorder = PEXArtifactRecorder(workspace: workspace)
        let started = ContinuousClock.now
        #expect(throws: PEXError.self) { try recorder.captureInput(url: fifo, kind: .layoutInput, maximumBytes: 4) }
        #expect(ContinuousClock.now - started < .seconds(1))
        let file = root.appending(path: "regular.gds")
        try Data([1, 2, 3, 4, 5]).write(to: file)
        #expect(throws: PEXError.self) { try recorder.captureInput(url: file, kind: .layoutInput, maximumBytes: 4) }
        let admitted = try recorder.captureInput(url: file, kind: .layoutInput, maximumBytes: 5)
        #expect(admitted.reference?.byteCount == 5)
    }

    @Test func cancelledChunkReadDoesNotPublishCapturedBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cancelled-read-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Cleanup failed: \(error)") } }
        let file = root.appending(path: "input")
        try Data([1]).write(to: file)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try PEXBoundedInputReader().read(file)
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch let error as PEXError { #expect(error.kind == .cancelled) }
    }

    @Test func atomicReportPublicationNeverExposesPartialReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "atomic-publication-\(UUID())")
        let workspace = PEXRunWorkspace(baseURL: root, runID: PEXRunID())
        try workspace.createDirectories(corners: [])
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Cleanup failed: \(error)") } }
        let store = PEXArtifactStore(workspace: workspace)
        let first = String(repeating: "a", count: 131_072), second = String(repeating: "b", count: 131_072)
        try store.saveReport(first)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<100 { try store.saveReport(index.isMultiple(of: 2) ? first : second); await Task.yield() }
            }
            group.addTask {
                for _ in 0..<200 {
                    let read = try PEXBoundedInputReader().read(workspace.reportURL)
                    #expect(read == Data(first.utf8) || read == Data(second.utf8))
                    await Task.yield()
                }
            }
            try await group.waitForAll()
        }
        let valid = ParasiticIR(version: ParasiticIR.currentVersion, cornerID: "tt", units: .canonical,
            nets: [], elements: [], metadata: [:])
        try store.saveIR(valid, for: "tt")
        let original = try Data(contentsOf: workspace.cornerIRURL("tt"))
        let invalid = ParasiticIR(version: ParasiticIR.currentVersion, cornerID: "tt", units: .canonical,
            nets: [.init(name: NetName("N"), nodes: [], totalGroundCapF: .nan, totalCouplingCapF: 0, totalResistanceOhm: 0)],
            elements: [], metadata: [:])
        #expect(throws: PEXError.self) { try store.saveIR(invalid, for: "tt") }
        #expect(try Data(contentsOf: workspace.cornerIRURL("tt")) == original)
    }

}
