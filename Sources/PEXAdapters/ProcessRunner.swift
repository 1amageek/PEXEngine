import Foundation
import PEXCore
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public struct ProcessRunner: Sendable {
    public struct ProcessResult: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String

        public init(exitCode: Int32, stdout: String, stderr: String) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public let timeoutSeconds: Double
    public let terminationGraceSeconds: Double
    public let pipeDrainGraceSeconds: Double

    public init(
        timeoutSeconds: Double = 300,
        terminationGraceSeconds: Double = 2,
        pipeDrainGraceSeconds: Double = 0.25
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.terminationGraceSeconds = terminationGraceSeconds
        self.pipeDrainGraceSeconds = pipeDrainGraceSeconds
    }

    public func run(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) async throws -> ProcessResult {
        try await run(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            cancellationCheck: nil
        )
    }

    public func run(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        cancellationCheck: PEXExecutionContext.CancellationCheck?
    ) async throws -> ProcessResult {
        try await execute(makeRunConfiguration(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            cancellationCheck: cancellationCheck
        ))
    }

    private func makeRunConfiguration(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?,
        cancellationCheck: PEXExecutionContext.CancellationCheck?
    ) throws -> ProcessRunConfiguration {
        try validateConfiguration()
        return ProcessRunConfiguration(
            executablePath: executableURL.path(percentEncoded: false),
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds,
            terminationGraceSeconds: terminationGraceSeconds,
            pipeDrainGraceSeconds: pipeDrainGraceSeconds,
            cancellationCheck: cancellationCheck
        )
    }

    private func execute(_ configuration: ProcessRunConfiguration) async throws -> ProcessResult {
        if Task.isCancelled {
            throw PEXError(
                kind: .cancelled,
                stage: .backendExecution,
                message: "Process cancelled before launch: \(configuration.executablePath)"
            )
        }
        if let cancellationCheck = configuration.cancellationCheck, try await cancellationCheck() {
            throw PEXError(
                kind: .cancelled,
                stage: .backendExecution,
                message: "Process cancelled before launch: \(configuration.executablePath)"
            )
        }
        let cancellationBox = ProcessTaskCancellationBox(
            terminationGraceSeconds: configuration.terminationGraceSeconds
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startSession(
                    ProcessRunSession(configuration: configuration, continuation: continuation),
                    cancellationBox: cancellationBox
                )
            }
        } onCancel: {
            cancellationBox.cancel()
        }
    }

    private func startSession(_ session: ProcessRunSession, cancellationBox: ProcessTaskCancellationBox) {
        cancellationBox.register(completionBox: session.state)
        if cancellationBox.isCancelled {
            cancelBeforeLaunch(session)
            return
        }
        let resume = makeResumeHandler(session: session)
        let finalizeIfReady = makeFinalizeHandler(state: session.state, resume: resume)
        let scheduleForcedFinalize = makeForcedFinalizeScheduler(
            state: session.state,
            pipeDrainGraceSeconds: session.configuration.pipeDrainGraceSeconds,
            finalizeIfReady: finalizeIfReady
        )
        installReadabilityHandlers(session: session, finalizeIfReady: finalizeIfReady)
        guard let launch = launchOrFail(session) else { return }
        if cancellationBox.register(launch: launch) {
            session.state.markCancelled()
            cancellationBox.terminateLaunchRegisteredAfterCancellation(launch)
        }
        scheduleExitWaiter(
            launch: launch,
            state: session.state,
            pipeDrainGraceSeconds: session.configuration.pipeDrainGraceSeconds,
            terminationGraceSeconds: session.configuration.terminationGraceSeconds,
            finalizeIfReady: finalizeIfReady,
            scheduleForcedFinalize: scheduleForcedFinalize
        )
        scheduleDeadlineMonitor(
            launch: launch,
            state: session.state,
            timeoutSeconds: session.configuration.timeoutSeconds,
            terminationGraceSeconds: session.configuration.terminationGraceSeconds,
            cancellationCheck: session.configuration.cancellationCheck,
            scheduleForcedFinalize: scheduleForcedFinalize
        )
    }

    private func cancelBeforeLaunch(_ session: ProcessRunSession) {
        session.outputPipe.fileHandleForWriting.closeFile()
        session.errorPipe.fileHandleForWriting.closeFile()
        guard session.state.markResumedIfNeeded() else { return }
        session.outputPipe.fileHandleForReading.readabilityHandler = nil
        session.errorPipe.fileHandleForReading.readabilityHandler = nil
        session.outputPipe.fileHandleForReading.closeFile()
        session.errorPipe.fileHandleForReading.closeFile()
        session.continuation.resume(throwing: PEXError(
            kind: .cancelled,
            stage: .backendExecution,
            message: "Process cancelled before launch: \(session.configuration.executablePath)"
        ))
    }

    private func makeResumeHandler(session: ProcessRunSession) -> @Sendable (ProcessCompletionSnapshot) -> Void {
        { snapshot in
            session.outputPipe.fileHandleForReading.readabilityHandler = nil
            session.errorPipe.fileHandleForReading.readabilityHandler = nil
            if !snapshot.forced {
                let remainingOutput = Self.drainAvailableData(from: session.outputPipe.fileHandleForReading)
                let remainingError = Self.drainAvailableData(from: session.errorPipe.fileHandleForReading)
                if !remainingOutput.isEmpty {
                    session.stdoutBuf.append(remainingOutput)
                }
                if !remainingError.isEmpty {
                    session.stderrBuf.append(remainingError)
                }
            }
            session.outputPipe.fileHandleForReading.closeFile()
            session.errorPipe.fileHandleForReading.closeFile()

            let out = session.stdoutBuf.snapshot()
            let err = session.stderrBuf.snapshot()
            if let failure = snapshot.failure {
                session.continuation.resume(throwing: failure)
                return
            }
            if snapshot.didCancel {
                session.continuation.resume(throwing: cancellationError(
                    executablePath: session.configuration.executablePath,
                    out: out,
                    err: err
                ))
                return
            }
            if snapshot.didTimeout {
                session.continuation.resume(throwing: timeoutError(
                    executablePath: session.configuration.executablePath,
                    timeoutSeconds: session.configuration.timeoutSeconds,
                    out: out,
                    err: err
                ))
                return
            }
            session.continuation.resume(returning: ProcessResult(
                exitCode: snapshot.exitCode,
                stdout: Self.utf8String(from: out),
                stderr: Self.utf8String(from: err)
            ))
        }
    }

    private func makeFinalizeHandler(
        state: ProcessCompletionBox,
        resume: @escaping @Sendable (ProcessCompletionSnapshot) -> Void
    ) -> @Sendable (_ force: Bool) -> Void {
        { force in
            let snapshot = state.snapshotIfReady(force: force)
            guard let snapshot else { return }
            resume(snapshot)
        }
    }

    private func makeForcedFinalizeScheduler(
        state: ProcessCompletionBox,
        pipeDrainGraceSeconds: Double,
        finalizeIfReady: @escaping @Sendable (_ force: Bool) -> Void
    ) -> @Sendable () -> Void {
        {
            guard state.markForcedFinalizeScheduledIfNeeded() else { return }
            Task.detached { @Sendable in
                do {
                    try await Self.sleep(seconds: pipeDrainGraceSeconds)
                } catch {
                    return
                }
                finalizeIfReady(true)
            }
        }
    }

    private func installReadabilityHandlers(
        session: ProcessRunSession,
        finalizeIfReady: @escaping @Sendable (_ force: Bool) -> Void
    ) {
        session.outputPipe.fileHandleForReading.readabilityHandler = { handle in
            Self.drainAvailableData(
                from: handle,
                into: session.stdoutBuf,
                markClosed: session.state.markStdoutClosed,
                finalizeIfReady: finalizeIfReady
            )
        }
        session.errorPipe.fileHandleForReading.readabilityHandler = { handle in
            Self.drainAvailableData(
                from: handle,
                into: session.stderrBuf,
                markClosed: session.state.markStderrClosed,
                finalizeIfReady: finalizeIfReady
            )
        }
    }

    private static func drainAvailableData(
        from handle: FileHandle,
        into buffer: ProcessOutputBuffer,
        markClosed: @escaping @Sendable () -> Void,
        finalizeIfReady: @escaping @Sendable (_ force: Bool) -> Void
    ) {
        let data = handle.availableData
        if data.isEmpty {
            handle.readabilityHandler = nil
            markClosed()
            finalizeIfReady(false)
        } else {
            buffer.append(data)
        }
    }

    private static func drainAvailableData(from handle: FileHandle) -> Data {
        handle.availableData
    }

    private func launchProcess(_ session: ProcessRunSession) throws -> ProcessLaunch {
        let processID = try ProcessSpawner.spawnInNewProcessGroup(
            executablePath: session.configuration.executablePath,
            arguments: session.configuration.arguments,
            environment: session.configuration.environment,
            workingDirectory: session.configuration.workingDirectory,
            outputPipe: session.outputPipe,
            errorPipe: session.errorPipe
        )
        session.outputPipe.fileHandleForWriting.closeFile()
        session.errorPipe.fileHandleForWriting.closeFile()
        return ProcessLaunch(
            processID: processID,
            processGroupID: ProcessSpawner.processGroupID(for: processID) ?? processID
        )
    }

    private func launchOrFail(_ session: ProcessRunSession) -> ProcessLaunch? {
        do {
            return try launchProcess(session)
        } catch {
            failLaunch(error, session: session)
            return nil
        }
    }

    private func failLaunch(_ error: any Error, session: ProcessRunSession) {
        session.outputPipe.fileHandleForWriting.closeFile()
        session.errorPipe.fileHandleForWriting.closeFile()
        guard session.state.markResumedIfNeeded() else { return }
        session.outputPipe.fileHandleForReading.readabilityHandler = nil
        session.errorPipe.fileHandleForReading.readabilityHandler = nil
        session.outputPipe.fileHandleForReading.closeFile()
        session.errorPipe.fileHandleForReading.closeFile()
        session.continuation.resume(throwing: PEXError(
            kind: .backendExecutionFailed,
            stage: .backendExecution,
            message: "Failed to launch process: \(session.configuration.executablePath)",
            underlyingDescription: String(describing: error)
        ))
    }

    private func scheduleExitWaiter(
        launch: ProcessLaunch,
        state: ProcessCompletionBox,
        pipeDrainGraceSeconds: Double,
        terminationGraceSeconds: Double,
        finalizeIfReady: @escaping @Sendable (_ force: Bool) -> Void,
        scheduleForcedFinalize: @escaping @Sendable () -> Void
    ) {
        Thread {
            let observation = ProcessSpawner.observeProcessExitWithoutReaping(processID: launch.processID)
            let exitCode = observation?.exitCode ?? ProcessSpawner.reapProcessExit(processID: launch.processID)
            Task.detached { @Sendable in
                state.markProcessTerminated(exitCode: exitCode)
                await Self.waitForPipeDrainIfNeeded(state: state, pipeDrainGraceSeconds: pipeDrainGraceSeconds)
                if observation != nil {
                    await Self.cleanupProcessGroupBeforeReapIfNeeded(
                        launch: launch,
                        state: state,
                        terminationGraceSeconds: terminationGraceSeconds
                    )
                    _ = ProcessSpawner.reapProcessExit(processID: launch.processID)
                }
                state.markProcessGroupCleanupComplete()
                finalizeIfReady(false)
                scheduleForcedFinalize()
            }
        }.start()
    }

    private func scheduleDeadlineMonitor(
        launch: ProcessLaunch,
        state: ProcessCompletionBox,
        timeoutSeconds: Double,
        terminationGraceSeconds: Double,
        cancellationCheck: PEXExecutionContext.CancellationCheck?,
        scheduleForcedFinalize: @escaping @Sendable () -> Void
    ) {
        Task.detached { @Sendable in
            let signalled = await Self.monitorUntilDeadline(
                launch: launch,
                state: state,
                timeoutSeconds: timeoutSeconds,
                cancellationCheck: cancellationCheck
            )
            guard signalled else { return }
            await Self.killAfterGraceIfStillRunning(
                launch: launch,
                terminationGraceSeconds: terminationGraceSeconds
            )
            scheduleForcedFinalize()
        }
    }

    private static func waitForPipeDrainIfNeeded(
        state: ProcessCompletionBox,
        pipeDrainGraceSeconds: Double
    ) async {
        guard !state.pipesClosed else { return }
        do {
            try await sleep(seconds: pipeDrainGraceSeconds)
        } catch {
            return
        }
    }

    private static func cleanupProcessGroupBeforeReapIfNeeded(
        launch: ProcessLaunch,
        state: ProcessCompletionBox,
        terminationGraceSeconds: Double
    ) async {
        guard ProcessSpawner.isProcessGroupAlive(launch.processGroupID) else { return }
        let didSignalProcessGroup = ProcessSpawner.sendSignalToProcessGroup(
            processID: launch.processID,
            processGroupID: launch.processGroupID,
            signal: SIGTERM
        )
        guard didSignalProcessGroup else { return }
        if !state.pipesClosed {
            do {
                try await sleep(seconds: terminationGraceSeconds)
            } catch {
                return
            }
        }
        if ProcessSpawner.isProcessGroupAlive(launch.processGroupID) {
            _ = ProcessSpawner.sendSignalToProcessGroup(
                processID: launch.processID,
                processGroupID: launch.processGroupID,
                signal: SIGKILL
            )
        }
    }

    private static func monitorUntilDeadline(
        launch: ProcessLaunch,
        state: ProcessCompletionBox,
        timeoutSeconds: Double,
        cancellationCheck: PEXExecutionContext.CancellationCheck?
    ) async -> Bool {
        let startedAt = Date()
        while true {
            do {
                try await sleep(seconds: 0.1)
            } catch {
                return false
            }
            if state.shouldStopMonitoring { return false }
            if let cancellationCheck {
                do {
                    if try await cancellationCheck() {
                        signalDeadline(launch: launch, state: state, markDeadline: state.markCancelled)
                        return true
                    }
                } catch {
                    let failure = PEXError(
                        kind: .backendExecutionFailed,
                        stage: .backendExecution,
                        message: "Process cancellation check failed",
                        underlyingDescription: String(describing: error)
                    )
                    signalDeadline(launch: launch, state: state) {
                        state.markFailed(failure)
                    }
                    return true
                }
            }
            if Date().timeIntervalSince(startedAt) >= timeoutSeconds {
                signalDeadline(launch: launch, state: state, markDeadline: state.markTimedOut)
                return true
            }
        }
    }

    private static func signalDeadline(
        launch: ProcessLaunch,
        state: ProcessCompletionBox,
        markDeadline: @escaping @Sendable () -> Void
    ) {
        markDeadline()
        _ = ProcessSpawner.sendSignalToProcessGroup(
            processID: launch.processID,
            processGroupID: launch.processGroupID,
            signal: SIGTERM
        )
    }

    private static func killAfterGraceIfStillRunning(
        launch: ProcessLaunch,
        terminationGraceSeconds: Double
    ) async {
        do {
            try await sleep(seconds: terminationGraceSeconds)
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

    private func cancellationError(executablePath: String, out: Data, err: Data) -> PEXError {
        var combinedData = out
        combinedData.append(err)
        return PEXError(
            kind: .cancelled,
            stage: .backendExecution,
            message: "Process cancelled: \(executablePath)",
            underlyingDescription: Self.utf8String(from: combinedData)
        )
    }

    private func timeoutError(executablePath: String, timeoutSeconds: Double, out: Data, err: Data) -> PEXError {
        var combinedData = out
        combinedData.append(err)
        return PEXError(
            kind: .backendExecutionFailed,
            stage: .backendExecution,
            message: "Process timed out after \(timeoutSeconds)s: \(executablePath)",
            underlyingDescription: Self.utf8String(from: combinedData)
        )
    }

    private static func utf8String(from data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private static func sleep(seconds: Double) async throws {
        let boundedSeconds = max(0, seconds)
        let nanoseconds = UInt64((boundedSeconds * 1_000_000_000).rounded())
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private func validateConfiguration() throws {
        try Self.validatePositiveFinite(timeoutSeconds, name: "timeoutSeconds")
        try Self.validatePositiveFinite(terminationGraceSeconds, name: "terminationGraceSeconds")
        try Self.validatePositiveFinite(pipeDrainGraceSeconds, name: "pipeDrainGraceSeconds")
    }

    private static func validatePositiveFinite(_ value: Double, name: String) throws {
        guard value.isFinite, value > 0 else {
            throw PEXError.invalidInput("\(name) must be a positive finite value")
        }
    }

}
