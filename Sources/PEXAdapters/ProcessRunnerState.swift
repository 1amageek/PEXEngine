import Foundation
import PEXCore
import Synchronization
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

struct ProcessLaunch: Sendable {
    let processID: pid_t
    let processGroupID: pid_t
}

struct ProcessRunConfiguration: Sendable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]?
    let workingDirectory: URL?
    let timeoutSeconds: Double
    let terminationGraceSeconds: Double
    let pipeDrainGraceSeconds: Double
    let cancellationCheck: PEXExecutionContext.CancellationCheck?
}

struct ProcessRunSession {
    let configuration: ProcessRunConfiguration
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let stdoutBuf = ProcessOutputBuffer()
    let stderrBuf = ProcessOutputBuffer()
    let state = ProcessCompletionBox()
    let continuation: CheckedContinuation<ProcessRunner.ProcessResult, any Error>
}

final class ProcessTaskCancellationBox: Sendable {
    private struct State: Sendable {
        var wasCancelled = false
        var completionBox: ProcessCompletionBox?
        var launch: ProcessLaunch?
        var killScheduled = false
    }

    private let terminationGraceSeconds: Double
    private let storage = Mutex(State())

    init(terminationGraceSeconds: Double) {
        self.terminationGraceSeconds = terminationGraceSeconds
    }

    var isCancelled: Bool {
        storage.withLock { $0.wasCancelled }
    }

    func register(completionBox: ProcessCompletionBox) {
        let shouldMarkCancelled = storage.withLock { state -> Bool in
            state.completionBox = completionBox
            return state.wasCancelled
        }
        if shouldMarkCancelled {
            completionBox.markCancelled()
        }
    }

    func register(launch: ProcessLaunch) -> Bool {
        storage.withLock { state -> Bool in
            state.launch = launch
            return state.wasCancelled
        }
    }

    func cancel() {
        let snapshot = storage.withLock { state -> (ProcessCompletionBox?, ProcessLaunch?, Bool) in
            state.wasCancelled = true
            let shouldScheduleKill = state.launch != nil && !state.killScheduled
            if shouldScheduleKill {
                state.killScheduled = true
            }
            return (state.completionBox, state.launch, shouldScheduleKill)
        }
        snapshot.0?.markCancelled()
        if let launch = snapshot.1 {
            sendTerminationSignal(to: launch, scheduleKill: snapshot.2)
        }
    }

    func terminateLaunchRegisteredAfterCancellation(_ launch: ProcessLaunch) {
        let shouldScheduleKill = storage.withLock { state -> Bool in
            guard state.wasCancelled, !state.killScheduled else { return false }
            state.killScheduled = true
            return true
        }
        guard shouldScheduleKill else { return }
        sendTerminationSignal(to: launch, scheduleKill: true)
    }

    private func sendTerminationSignal(to launch: ProcessLaunch, scheduleKill: Bool) {
        _ = ProcessSpawner.sendSignalToProcessGroup(
            processID: launch.processID,
            processGroupID: launch.processGroupID,
            signal: SIGTERM
        )
        if scheduleKill {
            scheduleForcedKillIfNeeded(launch)
        }
    }

    private func scheduleForcedKillIfNeeded(_ launch: ProcessLaunch) {
        let graceSeconds = terminationGraceSeconds
        Task.detached { @Sendable in
            do {
                let boundedSeconds = max(0, graceSeconds)
                let nanoseconds = UInt64((boundedSeconds * 1_000_000_000).rounded())
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard ProcessSpawner.isProcessGroupAlive(launch.processGroupID) else { return }
            _ = ProcessSpawner.sendSignalToProcessGroup(
                processID: launch.processID,
                processGroupID: launch.processGroupID,
                signal: SIGKILL
            )
        }
    }
}

final class ProcessOutputBuffer: Sendable {
    private let storage = Mutex(Data())

    func append(_ data: Data) {
        storage.withLock { $0.append(data) }
    }

    func snapshot() -> Data {
        storage.withLock { $0 }
    }
}

final class ProcessCompletionBox: Sendable {
    private let storage = Mutex(ProcessCompletionState())

    var didResume: Bool {
        storage.withLock { $0.didResume }
    }

    var pipesClosed: Bool {
        storage.withLock { $0.pipesClosed }
    }

    var shouldStopMonitoring: Bool {
        storage.withLock { $0.didResume || $0.processTerminated }
    }

    func markStdoutClosed() {
        storage.withLock { $0.stdoutClosed = true }
    }

    func markStderrClosed() {
        storage.withLock { $0.stderrClosed = true }
    }

    func markProcessTerminated(exitCode: Int32) {
        storage.withLock {
            $0.processTerminated = true
            $0.exitCode = exitCode
        }
    }

    func markProcessGroupCleanupComplete() {
        storage.withLock { $0.processGroupCleanupComplete = true }
    }

    func markCancelled() {
        storage.withLock { $0.didCancel = true }
    }

    func markTimedOut() {
        storage.withLock { $0.didTimeout = true }
    }

    func markFailed(_ error: PEXError) {
        storage.withLock { $0.failure = error }
    }

    func markResumedIfNeeded() -> Bool {
        storage.withLock { completion -> Bool in
            guard !completion.didResume else { return false }
            completion.didResume = true
            return true
        }
    }

    func markForcedFinalizeScheduledIfNeeded() -> Bool {
        storage.withLock { completion -> Bool in
            guard !completion.didResume, !completion.forceFinalizeScheduled else { return false }
            completion.forceFinalizeScheduled = true
            return true
        }
    }

    func snapshotIfReady(force: Bool) -> ProcessCompletionSnapshot? {
        storage.withLock { completion -> ProcessCompletionSnapshot? in
            guard !completion.didResume else { return nil }
            guard force || completion.isComplete else { return nil }
            let forced = force && !completion.isComplete
            completion.didResume = true
            return completion.snapshot(forced: forced)
        }
    }
}

struct ProcessCompletionState: Sendable {
    var stdoutClosed = false
    var stderrClosed = false
    var processTerminated = false
    var processGroupCleanupComplete = false
    var exitCode: Int32 = 0
    var didCancel = false
    var didTimeout = false
    var failure: PEXError?
    var didResume = false
    var forceFinalizeScheduled = false

    var pipesClosed: Bool {
        stdoutClosed && stderrClosed
    }

    var isComplete: Bool {
        pipesClosed && processTerminated && processGroupCleanupComplete
    }

    func snapshot(forced: Bool) -> ProcessCompletionSnapshot {
        ProcessCompletionSnapshot(
            exitCode: exitCode,
            didCancel: didCancel,
            didTimeout: didTimeout,
            failure: failure,
            forced: forced
        )
    }
}

struct ProcessCompletionSnapshot: Sendable {
    let exitCode: Int32
    let didCancel: Bool
    let didTimeout: Bool
    let failure: PEXError?
    let forced: Bool
}
