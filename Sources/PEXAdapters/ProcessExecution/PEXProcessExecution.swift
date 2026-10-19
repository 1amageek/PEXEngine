import Foundation
import PEXCore
import SignoffToolSupport

/// PEX owns async observation; the runner owns process lifetime and cleanup.
enum PEXProcessExecution {
    private enum Completion: Sendable { case process(TimedProcessResult), monitorStopped }

    static func run(runner: any TimedProcessRunning, process: Process,
                    cancellationCheck: PEXExecutionContext.CancellationCheck?) async throws -> TimedProcessResult {
        let control = TimedProcessControl()
        do { if let check = cancellationCheck, try await check() { control.requestCancellation() } }
        catch { control.requestFailure(reason: String(describing: error)) }
        do { return try await withThrowingTaskGroup(of: Completion.self) { group in
            group.addTask { .process(try await runner.run(process: process, control: control)) }
            if let check = cancellationCheck { group.addTask {
                while !Task.isCancelled, control.request == nil {
                    do { if try await check() { control.requestCancellation() } }
                    catch is CancellationError {
                        if Task.isCancelled { return .monitorStopped }
                        control.requestFailure(reason: "CancellationError from the caller check")
                    }
                    catch { control.requestFailure(reason: String(describing: error)) }
                    do { try await Task.sleep(for: .milliseconds(20)) }
                    catch is CancellationError { return .monitorStopped }
                }
                return .monitorStopped
            } }
            defer { group.cancelAll() }
            while let completed = try await group.next() {
                if case .process(let result) = completed { return result }
            }
            throw PEXError.internalInvariantViolation("External process completed without a result")
        } } catch let error as TimedProcessError {
            if case .executionFailed(let failure) = error, let handle = failure.cleanupHandle {
                do { try await handle.close(timeoutSeconds: 5) }
                catch { throw PEXProcessCleanupFailure(processFailure: failure, retryFailure: String(describing: error)) }
            }
            throw error
        }
    }
}
