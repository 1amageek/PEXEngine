import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

enum ProcessSpawner {
    struct ProcessExitObservation: Sendable {
        let exitCode: Int32
    }

    static func spawnInNewProcessGroup(
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

        try configurePipeActions(&actions, outputPipe: outputPipe, errorPipe: errorPipe)
        try configureWorkingDirectory(&actions, workingDirectory: workingDirectory)
        try configureSpawnAttributes(&attributes)
        return try spawn(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            actions: &actions,
            attributes: &attributes
        )
    #else
        throw ProcessLaunchError.unsupportedPlatform
    #endif
    }

    static func observeProcessExitWithoutReaping(processID: pid_t) -> ProcessExitObservation? {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
        var info = siginfo_t()
        while true {
            let result = waitid(P_PID, id_t(processID), &info, WEXITED | WNOWAIT)
            if result == 0 {
                return ProcessExitObservation(exitCode: exitCode(fromSignalInfo: info))
            }
            if errno == EINTR {
                continue
            }
            return nil
        }
    #else
        return nil
    #endif
    }

    static func reapProcessExit(processID: pid_t) -> Int32 {
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

    static func waitForProcessExit(processID: pid_t) -> Int32 {
        reapProcessExit(processID: processID)
    }

    @discardableResult
    static func sendSignalToProcessGroup(
        processID: pid_t,
        processGroupID: pid_t,
        signal: Int32
    ) -> Bool {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
        guard processID > 0, processGroupID > 0, processGroupID != getpgrp() else {
            return false
        }
        return kill(-processGroupID, signal) == 0
    #else
        return false
    #endif
    }

    static func isProcessGroupAlive(_ processGroupID: pid_t) -> Bool {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
        guard processGroupID > 0, processGroupID != getpgrp() else {
            return false
        }
        if kill(-processGroupID, 0) == 0 {
            return true
        }
        return errno == EPERM
    #else
        return false
    #endif
    }

    static func processGroupID(for processID: pid_t) -> pid_t? {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
        let processGroupID = getpgid(processID)
        return processGroupID >= 0 ? processGroupID : nil
    #else
        return nil
    #endif
    }

    private static func configurePipeActions(
        _ actions: inout posix_spawn_file_actions_t?,
        outputPipe: Pipe,
        errorPipe: Pipe
    ) throws {
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
    }

    private static func configureWorkingDirectory(
        _ actions: inout posix_spawn_file_actions_t?,
        workingDirectory: URL?
    ) throws {
        guard let workingDirectory else { return }
        let directoryPath = workingDirectory.path(percentEncoded: false)
        try directoryPath.withCString { path in
            try requirePOSIXSuccess(
                addChangeDirectoryFileAction(&actions, path: path),
                operation: "posix_spawn_file_actions_addchdir"
            )
        }
    }

    private static func configureSpawnAttributes(_ attributes: inout posix_spawnattr_t?) throws {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        try requirePOSIXSuccess(
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)),
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
    }

    private static func spawn(
        executablePath: String,
        arguments: [String],
        environment: [String: String]?,
        actions: inout posix_spawn_file_actions_t?,
        attributes: inout posix_spawnattr_t?
    ) throws -> pid_t {
        let argv = try POSIXCStringArray([executablePath] + arguments)
        let envp = try environment.map { env in
            try POSIXCStringArray(env.keys.sorted().map { key in "\(key)=\(env[key] ?? "")" })
        }

        var processID = pid_t()
        let spawnResult = try executablePath.withCString { executablePointer in
            try argv.withUnsafeMutablePointers { argvPointer in
                if let envp {
                    return try envp.withUnsafeMutablePointers { envPointer in
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

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let terminationSignal = status & 0x7f
        if terminationSignal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + terminationSignal
    }

    private static func exitCode(fromSignalInfo info: siginfo_t) -> Int32 {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux)
        if info.si_code == CLD_EXITED {
            return Int32(info.si_status)
        }
        return 128 + Int32(info.si_status)
    #else
        return -1
    #endif
    }
}
