import Foundation
import PEXCore
import Synchronization

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

    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        if let environment {
            process.environment = environment
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // 両パイプを並行ドレイン + プロセス終了を待機。
        // readabilityHandler は libdispatch 上で動作し、cooperative thread pool をブロックしない。
        // process.run() はハンドラ設定後に呼ぶ — 先に起動すると即終了時にイベントを逃す。
        return try await withCheckedThrowingContinuation { continuation in
            let stdoutBuf = Mutex(Data())
            let stderrBuf = Mutex(Data())
            let exitCodeBuf = Mutex<Int32>(0)
            let remaining = Mutex(3) // stdout EOF + stderr EOF + process exit

            let finish: @Sendable () -> Void = {
                let count = remaining.withLock { v -> Int in
                    v -= 1
                    return v
                }
                guard count == 0 else { return }
                let out = stdoutBuf.withLock { $0 }
                let err = stderrBuf.withLock { $0 }
                let code = exitCodeBuf.withLock { $0 }
                continuation.resume(returning: ProcessResult(
                    exitCode: code,
                    stdout: String(data: out, encoding: .utf8) ?? "",
                    stderr: String(data: err, encoding: .utf8) ?? ""
                ))
            }

            // 1. ハンドラ設定（process.run() より前）
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    finish()
                } else {
                    stdoutBuf.withLock { $0.append(data) }
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    finish()
                } else {
                    stderrBuf.withLock { $0.append(data) }
                }
            }

            process.terminationHandler = { @Sendable proc in
                exitCodeBuf.withLock { $0 = proc.terminationStatus }
                finish()
            }

            // 2. プロセス起動（ハンドラ設定済み → イベントを逃さない）
            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: PEXError(
                    kind: .backendExecutionFailed,
                    stage: .backendExecution,
                    message: "Failed to launch process: \(executableURL.path(percentEncoded: false))",
                    underlyingDescription: String(describing: error)
                ))
            }
        }
    }
}
