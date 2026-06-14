import Foundation
import PEXCore
import Synchronization
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
        try validateConfiguration()

        let timeoutSeconds = timeoutSeconds
        let terminationGraceSeconds = terminationGraceSeconds
        let pipeDrainGraceSeconds = pipeDrainGraceSeconds
        let executablePath = executableURL.path(percentEncoded: false)
        let outputPipe = Pipe()
        let errorPipe = Pipe()

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

            let processID: pid_t
            do {
                processID = try Self.spawnInNewProcessGroup(
                    executablePath: executablePath,
                    arguments: arguments,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    outputPipe: outputPipe,
                    errorPipe: errorPipe
                )
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
            let processGroupID = Self.processGroupID(for: processID) ?? processID

            Task.detached {
                let exitCode = Self.waitForProcessExit(processID: processID)
                state.withLock {
                    $0.processTerminated = true
                    $0.exitCode = exitCode
                }

                let pipesClosedAtExit = state.withLock { $0.pipesClosed }
                if !pipesClosedAtExit {
                    do {
                        try await Self.sleep(seconds: pipeDrainGraceSeconds)
                    } catch {
                        return
                    }
                }

                let shouldCleanProcessGroup = state.withLock { !$0.didResume }
                let didSignalProcessGroup: Bool
                if shouldCleanProcessGroup {
                    didSignalProcessGroup = Self.sendSignalToProcessGroup(
                        processID: processID,
                        processGroupID: processGroupID,
                        signal: SIGTERM
                    )
                } else {
                    didSignalProcessGroup = false
                }

                if didSignalProcessGroup {
                    do {
                        try await Self.sleep(seconds: terminationGraceSeconds)
                    } catch {
                        return
                    }
                    if state.withLock({ !$0.didResume }) {
                        _ = Self.sendSignalToProcessGroup(
                            processID: processID,
                            processGroupID: processGroupID,
                            signal: SIGKILL
                        )
                    }
                }

                state.withLock {
                    $0.processGroupCleanupComplete = true
                }
                finalizeIfReady(false)
                scheduleForcedFinalize()
            }

            Task.detached {
                let startedAt = Date()
                do {
                    while true {
                        try await Self.sleep(seconds: 0.1)
                        let shouldStop = state.withLock { $0.didResume || $0.processTerminated }
                        if shouldStop { return }
                        if Date().timeIntervalSince(startedAt) >= timeoutSeconds {
                            state.withLock { $0.didTimeout = true }
                            _ = Self.sendSignalToProcessGroup(
                                processID: processID,
                                processGroupID: processGroupID,
                                signal: SIGTERM
                            )
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
                if !state.withLock({ $0.processTerminated }) {
                    _ = Self.sendSignalToProcessGroup(
                        processID: processID,
                        processGroupID: processGroupID,
                        signal: SIGKILL
                    )
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

    private static func spawnInNewProcessGroup(
        executablePath: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?,
        outputPipe: Pipe,
        errorPipe: Pipe
    ) throws -> pid_t {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
        var actions: posix_spawn_file_actions_t? = nil
        try requirePOSIXSuccess(
            posix_spawn_file_actions_init(&actions),
            operation: "posix_spawn_file_actions_init"
        )
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attributes: posix_spawnattr_t? = nil
        try requirePOSIXSuccess(
            posix_spawnattr_init(&attributes),
            operation: "posix_spawnattr_init"
        )
        defer { posix_spawnattr_destroy(&attributes) }

        let outputReadFD = outputPipe.fileHandleForReading.fileDescriptor
        let outputWriteFD = outputPipe.fileHandleForWriting.fileDescriptor
        let errorReadFD = errorPipe.fileHandleForReading.fileDescriptor
        let errorWriteFD = errorPipe.fileHandleForWriting.fileDescriptor

        try addCloseFileAction(&actions, fileDescriptor: outputReadFD)
        try addCloseFileAction(&actions, fileDescriptor: errorReadFD)
        try addDuplicateFileAction(&actions, from: outputWriteFD, to: STDOUT_FILENO)
        try addDuplicateFileAction(&actions, from: errorWriteFD, to: STDERR_FILENO)
        if outputWriteFD != STDOUT_FILENO {
            try addCloseFileAction(&actions, fileDescriptor: outputWriteFD)
        }
        if errorWriteFD != STDERR_FILENO {
            try addCloseFileAction(&actions, fileDescriptor: errorWriteFD)
        }

        if let workingDirectory {
            let directoryPath = workingDirectory.path(percentEncoded: false)
            try directoryPath.withCString { path in
                try requirePOSIXSuccess(
                    addChangeDirectoryFileAction(&actions, path: path),
                    operation: "posix_spawn_file_actions_addchdir"
                )
            }
        }

    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        try requirePOSIXSuccess(
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)),
            operation: "posix_spawnattr_setflags"
        )
    #else
        try requirePOSIXSuccess(
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
            operation: "posix_spawnattr_setflags"
        )
        try requirePOSIXSuccess(
            posix_spawnattr_setpgroup(&attributes, 0),
            operation: "posix_spawnattr_setpgroup"
        )
    #endif

        let argv = try POSIXCStringArray([executablePath] + arguments)
        let envp = try environment.map { env in
            try POSIXCStringArray(env.keys.sorted().map { key in "\(key)=\(env[key] ?? "")" })
        }

        var processID = pid_t()
        let spawnResult = executablePath.withCString { executablePointer in
            argv.withUnsafeMutablePointers { argvPointer in
                if let envp {
                    return envp.withUnsafeMutablePointers { envPointer in
                        posix_spawn(
                            &processID,
                            executablePointer,
                            &actions,
                            &attributes,
                            argvPointer,
                            envPointer
                        )
                    }
                }
                return posix_spawn(
                    &processID,
                    executablePointer,
                    &actions,
                    &attributes,
                    argvPointer,
                    inheritedEnvironment
                )
            }
        }
        try requirePOSIXSuccess(spawnResult, operation: "posix_spawn")
        return processID
    #else
        throw ProcessLaunchError.unsupportedPlatform
    #endif
    }

    private static func addDuplicateFileAction(
        _ actions: inout posix_spawn_file_actions_t?,
        from source: Int32,
        to destination: Int32
    ) throws {
        try requirePOSIXSuccess(
            posix_spawn_file_actions_adddup2(&actions, source, destination),
            operation: "posix_spawn_file_actions_adddup2"
        )
    }

    private static func addCloseFileAction(
        _ actions: inout posix_spawn_file_actions_t?,
        fileDescriptor: Int32
    ) throws {
        try requirePOSIXSuccess(
            posix_spawn_file_actions_addclose(&actions, fileDescriptor),
            operation: "posix_spawn_file_actions_addclose"
        )
    }

    private static func addChangeDirectoryFileAction(
        _ actions: inout posix_spawn_file_actions_t?,
        path: UnsafePointer<CChar>
    ) -> Int32 {
    #if os(Linux)
        posix_spawn_file_actions_addchdir_np(&actions, path)
    #else
        posix_spawn_file_actions_addchdir(&actions, path)
    #endif
    }

    private static func requirePOSIXSuccess(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw ProcessLaunchError.posixFailure(operation: operation, code: result)
        }
    }

    private static var inheritedEnvironment: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        Darwin.environ
    #elseif os(Linux)
        Glibc.environ
    #endif
    }

    private static func waitForProcessExit(processID: pid_t) -> Int32 {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
        var status: Int32 = 0
        while true {
            let result = waitpid(processID, &status, 0)
            if result == processID {
                return exitCode(fromWaitStatus: status)
            }
            if result == -1, errno == EINTR {
                continue
            }
            return -1
        }
    #else
        return -1
    #endif
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let terminationSignal = status & 0x7f
        if terminationSignal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + terminationSignal
    }

    @discardableResult
    private static func sendSignalToProcessGroup(
        processID: pid_t,
        processGroupID: pid_t,
        signal: Int32
    ) -> Bool {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
        if processGroupID != getpgrp() {
            if kill(-processGroupID, signal) == 0 {
                return true
            }
            guard errno != ESRCH else { return false }
        }
        return kill(processID, signal) == 0
    #else
        return false
    #endif
    }

    private static func processGroupID(for processID: pid_t) -> pid_t? {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
        let processGroupID = getpgid(processID)
        return processGroupID >= 0 ? processGroupID : nil
    #else
        return nil
    #endif
    }
}

private final class POSIXCStringArray {
    private var pointers: [UnsafeMutablePointer<CChar>?] = []

    init(_ strings: [String]) throws {
        for string in strings {
            guard let pointer = strdup(string) else {
                throw ProcessLaunchError.posixFailure(operation: "strdup", code: ENOMEM)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
    }

    deinit {
        for pointer in pointers {
            free(pointer)
        }
    }

    func withUnsafeMutablePointers<R>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> R
    ) rethrows -> R {
        try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}

private enum ProcessLaunchError: Error, CustomStringConvertible {
    case posixFailure(operation: String, code: Int32)
    case unsupportedPlatform

    var description: String {
        switch self {
        case .posixFailure(let operation, let code):
            return "\(operation) failed with errno \(code): \(String(cString: strerror(code)))"
        case .unsupportedPlatform:
            return "Process groups are not supported on this platform"
        }
    }
}

private struct ProcessCompletionState: Sendable {
    var stdoutClosed = false
    var stderrClosed = false
    var processTerminated = false
    var processGroupCleanupComplete = false
    var exitCode: Int32 = 0
    var didTimeout = false
    var didResume = false
    var forceFinalizeScheduled = false

    var pipesClosed: Bool {
        stdoutClosed && stderrClosed
    }

    var isComplete: Bool {
        pipesClosed && processTerminated && processGroupCleanupComplete
    }

    var snapshot: ProcessCompletionSnapshot {
        ProcessCompletionSnapshot(exitCode: exitCode, didTimeout: didTimeout)
    }
}

private struct ProcessCompletionSnapshot: Sendable {
    let exitCode: Int32
    let didTimeout: Bool
}
