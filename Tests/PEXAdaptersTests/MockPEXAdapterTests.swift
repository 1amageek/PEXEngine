import Testing
import Foundation
import Synchronization
@testable import PEXCore
@testable import PEXAdapters

@Suite("MockPEXAdapter Tests")
struct MockPEXAdapterTests {
    private typealias ProcessRunnerCancellationFixture = (
        root: URL,
        childSurvivedURL: URL,
        executableURL: URL
    )

    @Test func adapterCapabilities() {
        let adapter = MockPEXAdapter()
        #expect(adapter.backendID == "mock")
        #expect(adapter.capabilities.supportsCouplingCaps == true)
        #expect(adapter.capabilities.supportsCornerSweep == true)
        #expect(adapter.capabilities.nativeOutputFormats.contains(.spef))
    }

    @Test func mockGeneratorProducesSPEF() {
        let generator = MockParasiticGenerator(
            topCell: "TEST",
            corner: PEXCorner(id: "tt_25c_1v0"),
            includeCouplingCaps: true
        )
        let spef = generator.generateSPEF()
        #expect(spef.contains("*SPEF"))
        #expect(spef.contains("*DESIGN \"TEST\""))
        #expect(spef.contains("*D_NET"))
        #expect(spef.contains("*CAP"))
        #expect(spef.contains("*RES"))
    }

    @Test func mockGeneratorProducesValidIR() {
        let generator = MockParasiticGenerator(
            topCell: "TEST",
            corner: PEXCorner(id: "tt"),
            includeCouplingCaps: true
        )
        let ir = generator.generateParasiticIR()
        #expect(!ir.nets.isEmpty)
        #expect(!ir.elements.isEmpty)
        #expect(ir.cornerID.value == "tt")

        let validator = ParasiticIRValidator()
        let result = validator.validate(ir)
        #expect(result.isValid, "Mock-generated IR should be valid")
    }

    // MARK: - ProcessRunner Tests

    @Test(.timeLimit(.minutes(1)))
    func processRunnerEchoStdout() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executableURL: URL(filePath: "/bin/echo"),
            arguments: ["hello", "world"]
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello world")
        #expect(result.stderr.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerPreservesInvalidUTF8Diagnostics() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", "printf '\\377'; printf '\\376' >&2"]
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == String(decoding: Data([0xff]), as: UTF8.self))
        #expect(result.stderr == String(decoding: Data([0xfe]), as: UTF8.self))
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerNonZeroExitCode() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", "exit 42"]
        )
        #expect(result.exitCode == 42)
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerImmediateExit() async throws {
        // Verifies that a process exiting immediately after handler setup does not hang.
        let runner = ProcessRunner()
        let result = try await runner.run(
            executableURL: URL(filePath: "/usr/bin/true")
        )
        #expect(result.exitCode == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerInvalidExecutableThrows() async {
        let runner = ProcessRunner()
        do {
            _ = try await runner.run(
                executableURL: URL(filePath: "/nonexistent/binary")
            )
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .backendExecutionFailed)
            #expect(error.message.contains("/nonexistent/binary"))
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerTimeoutTerminatesLongRunningProcess() async throws {
        let runner = ProcessRunner(timeoutSeconds: 0.1, terminationGraceSeconds: 0.05)
        do {
            _ = try await runner.run(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", "printf started; sleep 5"]
            )
            Issue.record("Expected timeout")
        } catch let error as PEXError {
            #expect(error.kind == .backendExecutionFailed)
            #expect(error.message.contains("timed out"))
            #expect(error.underlyingDescription?.contains("started") == true)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerTimeoutTerminatesChildProcessTree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PEXProcessRunnerTreeTimeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeTemporaryRoot(root) }

        let childSurvived = root.appending(path: "child-survived")
        let executable = try writeExecutable(
            named: "mock-process-tree",
            in: root,
            contents: """
            #!/bin/sh
            (
                sleep 1
                touch \(shellSingleQuoted(childSurvived.path(percentEncoded: false)))
            ) &
            printf started
            sleep 10
            """
        )

        let runner = ProcessRunner(
            timeoutSeconds: 0.1,
            terminationGraceSeconds: 0.05,
            pipeDrainGraceSeconds: 0.05
        )
        do {
            _ = try await runner.run(executableURL: executable)
            Issue.record("Expected timeout")
        } catch let error as PEXError {
            #expect(error.kind == .backendExecutionFailed)
            #expect(error.message.contains("timed out"))
        }

        try await Task.sleep(nanoseconds: 1_300_000_000)
        let didChildSurvive = FileManager.default.fileExists(atPath: childSurvived.path(percentEncoded: false))
        if didChildSurvive {
            Issue.record("ProcessRunner child process survived cancellation")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerEscalatesWhenLeaderDiesButChildIgnoresTerminate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PEXProcessRunnerLeaderDiesChildIgnoresTERM-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeTemporaryRoot(root) }

        let childSurvived = root.appending(path: "child-survived")
        let executable = try writeExecutable(
            named: "mock-leader-dies-child-ignores-term",
            in: root,
            contents: """
            #!/bin/sh
            trap 'exit 0' TERM
            (
                trap '' TERM
                sleep 1
                touch \(shellSingleQuoted(childSurvived.path(percentEncoded: false)))
            ) &
            printf started
            sleep 10
            """
        )

        let runner = ProcessRunner(
            timeoutSeconds: 0.1,
            terminationGraceSeconds: 0.05,
            pipeDrainGraceSeconds: 0.05
        )
        do {
            _ = try await runner.run(executableURL: executable)
            Issue.record("Expected timeout")
        } catch let error as PEXError {
            #expect(error.kind == .backendExecutionFailed)
            #expect(error.message.contains("timed out"))
        }

        try await Task.sleep(nanoseconds: 1_300_000_000)
        let didChildSurvive = FileManager.default.fileExists(atPath: childSurvived.path(percentEncoded: false))
        if didChildSurvive {
            Issue.record("ProcessRunner child process survived SIGKILL escalation after leader exit")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerCancellationCheckTerminatesChildProcessTree() async throws {
        let fixture = try makeProcessRunnerCancellationFixture()
        defer { removeTemporaryRoot(fixture.root) }

        let probe = CancellationProbe()
        let runner = processTreeCancellationRunner()

        let task = Task {
            try await runner.run(
                executableURL: fixture.executableURL,
                cancellationCheck: {
                    probe.isCancelled
                }
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        probe.cancel()

        await assertProcessRunnerCancellationFailure(task)
        try await assertProcessRunnerChildDidNotSurvive(fixture.childSurvivedURL)
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerTaskCancellationTerminatesChildProcessTree() async throws {
        let fixture = try makeProcessRunnerCancellationFixture()
        defer { removeTemporaryRoot(fixture.root) }

        let runner = processTreeCancellationRunner()
        let task = Task {
            try await runner.run(executableURL: fixture.executableURL)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        await assertProcessRunnerCancellationFailure(task)
        try await assertProcessRunnerChildDidNotSurvive(fixture.childSurvivedURL)
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerCancellationCheckFailureTerminatesChildProcessTree() async throws {
        let fixture = try makeProcessRunnerCancellationFixture()
        defer { removeTemporaryRoot(fixture.root) }

        let probe = ThrowingCancellationProbe()
        let runner = processTreeCancellationRunner()

        let task = Task {
            try await runner.run(
                executableURL: fixture.executableURL,
                cancellationCheck: {
                    try probe.check()
                }
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        probe.fail()

        await assertProcessRunnerCancellationCheckFailure(task)
        try await assertProcessRunnerChildDidNotSurvive(fixture.childSurvivedURL)
    }

    private func assertProcessRunnerCancellationCheckFailure(
        _ task: Task<ProcessRunner.ProcessResult, any Error>
    ) async {
        do {
            _ = try await task.value
            Issue.record("Expected cancellation check failure")
        } catch let error as PEXError {
            #expect(error.kind == .backendExecutionFailed)
            #expect(error.message.contains("cancellation check failed"))
        } catch {
            Issue.record("Unexpected cancellation check error: \(error)")
        }
    }

    private func makeProcessRunnerCancellationFixture() throws -> ProcessRunnerCancellationFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PEXProcessRunnerTreeCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let childSurvivedURL = root.appending(path: "child-survived")
        let executableURL = try writeExecutable(
            named: "mock-process-tree-cancel",
            in: root,
            contents: processTreeCancellationScriptBody(childSurvivedURL: childSurvivedURL)
        )
        return (
            root: root,
            childSurvivedURL: childSurvivedURL,
            executableURL: executableURL
        )
    }

    private func processTreeCancellationScriptBody(childSurvivedURL: URL) -> String {
        """
        #!/bin/sh
        trap '' TERM
        (
            trap '' TERM
            sleep 1
            touch \(shellSingleQuoted(childSurvivedURL.path(percentEncoded: false)))
        ) &
        printf started
        sleep 10
        """
    }

    private func processTreeCancellationRunner() -> ProcessRunner {
        ProcessRunner(
            timeoutSeconds: 5,
            terminationGraceSeconds: 0.05,
            pipeDrainGraceSeconds: 0.05
        )
    }

    private func assertProcessRunnerCancellationFailure(
        _ task: Task<ProcessRunner.ProcessResult, any Error>
    ) async {
        do {
            _ = try await task.value
            Issue.record("Expected process cancellation")
        } catch let error as PEXError {
            #expect(error.kind == .cancelled)
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
    }

    private func assertProcessRunnerChildDidNotSurvive(_ childSurvivedURL: URL) async throws {
        try await Task.sleep(nanoseconds: 1_300_000_000)
        #expect(!FileManager.default.fileExists(atPath: childSurvivedURL.path(percentEncoded: false)))
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerRejectsInvalidTimingConfiguration() async throws {
        let runner = ProcessRunner(timeoutSeconds: 0, terminationGraceSeconds: 0.05)
        do {
            _ = try await runner.run(executableURL: URL(filePath: "/usr/bin/true"))
            Issue.record("Expected invalid timing configuration")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("timeoutSeconds"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerDrainsLargeStdoutAndStderr() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PEXProcessRunnerLargeOutput-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeTemporaryRoot(root) }

        let executable = try writeExecutable(
            named: "mock-large-output",
            in: root,
            contents: """
            #!/usr/bin/env perl
            print "O" x 200000;
            print STDERR "E" x 160000;
            exit 0;
            """
        )

        let result = try await ProcessRunner().run(executableURL: executable)

        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 200_000)
        #expect(result.stderr.count == 160_000)
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerDoesNotWaitForInheritedPipeEOFAfterParentExit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PEXProcessRunnerPipeInheritance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeTemporaryRoot(root) }

        let childFinished = root.appending(path: "child-finished")
        let executable = try writeExecutable(
            named: "mock-parent-exit",
            in: root,
            contents: """
            #!/bin/sh
            (
                sleep 0.4;
                touch \(shellSingleQuoted(childFinished.path(percentEncoded: false)))
            ) &
            printf "parent-exited\\n"
            exit 0;
            """
        )

        let runner = ProcessRunner(
            timeoutSeconds: 5.0,
            terminationGraceSeconds: 0.05,
            pipeDrainGraceSeconds: 0.05
        )
        let result = try await runner.run(executableURL: executable)

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("parent-exited"))

        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(!FileManager.default.fileExists(atPath: childFinished.path(percentEncoded: false)))
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerEscalatesAfterParentExitWhenChildIgnoresTerminate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PEXProcessRunnerParentExitChildIgnoresTERM-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeTemporaryRoot(root) }

        let childSurvived = root.appending(path: "child-survived")
        let executable = try writeExecutable(
            named: "mock-parent-exit-child-ignores-term",
            in: root,
            contents: """
            #!/bin/sh
            (
                trap '' TERM
                sleep 1
                touch \(shellSingleQuoted(childSurvived.path(percentEncoded: false)))
            ) &
            printf "parent-exited\\n"
            exit 0
            """
        )

        let runner = ProcessRunner(
            timeoutSeconds: 5.0,
            terminationGraceSeconds: 0.05,
            pipeDrainGraceSeconds: 0.05
        )
        let result = try await runner.run(executableURL: executable)

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("parent-exited"))

        try await Task.sleep(nanoseconds: 1_300_000_000)
        #expect(!FileManager.default.fileExists(atPath: childSurvived.path(percentEncoded: false)))
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerCleansChildAfterParentExitWhenChildClosesPipes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PEXProcessRunnerParentExitChildClosesPipes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeTemporaryRoot(root) }

        let childSurvived = root.appending(path: "child-survived")
        let executable = try writeExecutable(
            named: "mock-parent-exit-child-closes-pipes",
            in: root,
            contents: """
            #!/bin/sh
            (
                exec >/dev/null 2>/dev/null
                trap '' TERM
                sleep 1
                touch \(shellSingleQuoted(childSurvived.path(percentEncoded: false)))
            ) &
            printf "parent-exited\\n"
            exit 0
            """
        )

        let runner = ProcessRunner(
            timeoutSeconds: 5.0,
            terminationGraceSeconds: 0.05,
            pipeDrainGraceSeconds: 0.05
        )
        let result = try await runner.run(executableURL: executable)

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("parent-exited"))

        try await Task.sleep(nanoseconds: 1_300_000_000)
        #expect(!FileManager.default.fileExists(atPath: childSurvived.path(percentEncoded: false)))
    }

    @Test func processSpawnerRejectsInvalidProcessGroupIdentifiers() {
        #expect(
            !ProcessSpawner.sendSignalToProcessGroup(
                processID: 0,
                processGroupID: 0,
                signal: 0
            )
        )
        #expect(
            !ProcessSpawner.sendSignalToProcessGroup(
                processID: -1,
                processGroupID: -1,
                signal: 0
            )
        )
        #expect(!ProcessSpawner.isProcessGroupAlive(0))
        #expect(!ProcessSpawner.isProcessGroupAlive(-1))
    }

    @Test func temperatureScalesValues() {
        let coldCorner = PEXCorner(id: PEXCornerID("cold"), name: "cold", temperature: -40)
        let hotCorner = PEXCorner(id: PEXCornerID("hot"), name: "hot", temperature: 125)

        let coldGen = MockParasiticGenerator(topCell: "T", corner: coldCorner)
        let hotGen = MockParasiticGenerator(topCell: "T", corner: hotCorner)

        let coldIR = coldGen.generateParasiticIR()
        let hotIR = hotGen.generateParasiticIR()

        // Hot corner should have larger parasitic values due to temperature scaling
        let coldTotal = coldIR.elements.reduce(0.0) { $0 + $1.value }
        let hotTotal = hotIR.elements.reduce(0.0) { $0 + $1.value }
        #expect(hotTotal > coldTotal)
    }

    private func removeTemporaryRoot(_ root: URL) {
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            Issue.record("Failed to remove temporary root: \(error)")
        }
    }

    private func writeExecutable(named name: String, in root: URL, contents: String) throws -> URL {
        let url = root.appending(path: name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path(percentEncoded: false)
        )
        return url
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private final class CancellationProbe: Sendable {
    private let state = Mutex(false)

    var isCancelled: Bool {
        state.withLock { $0 }
    }

    func cancel() {
        state.withLock { $0 = true }
    }
}

private final class ThrowingCancellationProbe: Sendable {
    private let state = Mutex(false)

    func check() throws -> Bool {
        if state.withLock({ $0 }) {
            throw CancellationCheckProbeError()
        }
        return false
    }

    func fail() {
        state.withLock { $0 = true }
    }
}

private struct CancellationCheckProbeError: Error, Sendable, CustomStringConvertible {
    var description: String {
        "cancellation check probe failure"
    }
}
