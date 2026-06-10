import Foundation
import PEXCore
import Synchronization
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
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
        try validateConfiguration()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        if let environment {
            process.environment = environment
        }

        let timeoutSeconds = timeoutSeconds
        let terminationGraceSeconds = terminationGraceSeconds
        let pipeDrainGraceSeconds = pipeDrainGraceSeconds
        let executablePath = executableURL.path(percentEncoded: false)
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Drain both pipes while the process runs so a verbose tool cannot block
        // on a full pipe before exiting.
        return try await withCheckedThrowingContinuation { continuation in
            let stdoutBuf = Mutex(Data())
            let stderrBuf = Mutex(Data())
            let state = Mutex(ProcessCompletionState())

            let resume: @Sendable (ProcessCompletionSnapshot) -> Void = { snapshot in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                outputPipe.fileHandleForReading.closeFile()
                errorPipe.fileHandleForReading.closeFile()

                let out = stdoutBuf.withLock { $0 }
                let err = stderrBuf.withLock { $0 }

                if snapshot.didTimeout {
                    var combinedData = out
                    combinedData.append(err)
                    continuation.resume(throwing: PEXError(
                        kind: .backendExecutionFailed,
                        stage: .backendExecution,
                        message: "Process timed out after \(timeoutSeconds)s: \(executablePath)",
                        underlyingDescription: String(data: combinedData, encoding: .utf8)
                    ))
                    return
                }

                continuation.resume(returning: ProcessResult(
                    exitCode: snapshot.exitCode,
                    stdout: String(data: out, encoding: .utf8) ?? "",
                    stderr: String(data: err, encoding: .utf8) ?? ""
                ))
            }

            let finalizeIfReady: @Sendable (_ force: Bool) -> Void = { force in
                let snapshot = state.withLock { completion -> ProcessCompletionSnapshot? in
                    guard !completion.didResume else { return nil }
                    guard force || completion.isComplete else { return nil }
                    completion.didResume = true
                    return completion.snapshot
                }
                guard let snapshot else { return }
                resume(snapshot)
            }

            let scheduleForcedFinalize: @Sendable () -> Void = {
                let shouldSchedule = state.withLock { completion -> Bool in
                    guard !completion.didResume, !completion.forceFinalizeScheduled else { return false }
                    completion.forceFinalizeScheduled = true
                    return true
                }
                guard shouldSchedule else { return }
                Task.detached {
                    do {
                        try await Self.sleep(seconds: pipeDrainGraceSeconds)
                    } catch {
                        return
                    }
                    finalizeIfReady(true)
                }
            }

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    state.withLock { $0.stdoutClosed = true }
                    finalizeIfReady(false)
                } else {
                    stdoutBuf.withLock { $0.append(data) }
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    state.withLock { $0.stderrClosed = true }
                    finalizeIfReady(false)
                } else {
                    stderrBuf.withLock { $0.append(data) }
                }
            }

            process.terminationHandler = { @Sendable proc in
                state.withLock {
                    $0.processTerminated = true
                    $0.exitCode = proc.terminationStatus
                }
                finalizeIfReady(false)
                scheduleForcedFinalize()
            }

            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForWriting.closeFile()
                errorPipe.fileHandleForWriting.closeFile()
                let shouldResume = state.withLock { completion -> Bool in
                    guard !completion.didResume else { return false }
                    completion.didResume = true
                    return true
                }
                if shouldResume {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    outputPipe.fileHandleForReading.closeFile()
                    errorPipe.fileHandleForReading.closeFile()
                    continuation.resume(throwing: PEXError(
                        kind: .backendExecutionFailed,
                        stage: .backendExecution,
                        message: "Failed to launch process: \(executablePath)",
                        underlyingDescription: String(describing: error)
                    ))
                }
                return
            }
            outputPipe.fileHandleForWriting.closeFile()
            errorPipe.fileHandleForWriting.closeFile()

            Task.detached {
                let startedAt = Date()
                do {
                    while true {
                        try await Self.sleep(seconds: 0.1)
                        let shouldStop = state.withLock { $0.didResume || $0.processTerminated }
                        if shouldStop { return }
                        if Date().timeIntervalSince(startedAt) >= timeoutSeconds {
                            state.withLock { $0.didTimeout = true }
                            process.terminate()
                            break
                        }
                    }
                } catch {
                    return
                }

                do {
                    try await Self.sleep(seconds: terminationGraceSeconds)
                } catch {
                    return
                }
                if state.withLock({ $0.didResume }) { return }
                if process.isRunning {
                #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                    kill(process.processIdentifier, SIGKILL)
                #else
                    process.terminate()
                #endif
                }
                scheduleForcedFinalize()
            }
        }
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

private struct ProcessCompletionState: Sendable {
    var stdoutClosed = false
    var stderrClosed = false
    var processTerminated = false
    var exitCode: Int32 = 0
    var didTimeout = false
    var didResume = false
    var forceFinalizeScheduled = false

    var isComplete: Bool {
        stdoutClosed && stderrClosed && processTerminated
    }

    var snapshot: ProcessCompletionSnapshot {
        ProcessCompletionSnapshot(exitCode: exitCode, didTimeout: didTimeout)
    }
}

private struct ProcessCompletionSnapshot: Sendable {
    let exitCode: Int32
    let didTimeout: Bool
}
