import Foundation
import Darwin
import PEXCore

public struct PEXBoundedInputReader: Sendable {
    /// Operational single-file admission; callers can select a different positive ceiling.
    public static let defaultMaximumBytes = 256 * 1024 * 1024
    public init() {}

    public func read(_ url: URL, maximumBytes: Int = Self.defaultMaximumBytes) throws -> Data {
        guard maximumBytes > 0, url.isFileURL, !url.path.utf8.contains(0) else { throw PEXError.invalidInput("Bounded input requires a local file and positive byte ceiling") }
        // Nonblocking open cannot wait for a FIFO writer. Type admission applies to
        // this owned descriptor, so replacing the path cannot substitute a special file.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw PEXError.persistenceFailed("Failed to open native input: \(url.path); errno=\(errno)") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            let closeResult = Darwin.close(descriptor)
            guard closeResult == 0 else { throw PEXError.persistenceFailed("Nonregular input refusal and descriptor close failed: \(url.path)") }
            throw PEXError.invalidInput("Input is not a regular file: \(url.path)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data: Data
        do {
            guard info.st_size >= 0, info.st_size <= maximumBytes else { throw PEXError.invalidInput("Input exceeds byte ceiling: \(url.path)") }
            var buffer = Data()
            while true {
                if Task.isCancelled { throw PEXError(kind: .cancelled, stage: .inputValidation, message: "Input capture cancelled") }
                let remaining = maximumBytes - buffer.count
                let count = remaining >= 256 * 1024 ? 256 * 1024 : remaining + 1
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                guard chunk.count <= remaining else { throw PEXError.invalidInput("Input exceeds byte ceiling: \(url.path)") }
                buffer.append(chunk)
            }
            data = buffer
        } catch {
            do { try handle.close() }
            catch let closeError { throw PEXError.persistenceFailed("Input read and close failed: \(error); \(closeError)") }
            if let error = error as? PEXError { throw error }
            throw PEXError.persistenceFailed("Failed to read input: \(url.path)", underlying: error)
        }
        do { try handle.close() }
        catch { throw PEXError.persistenceFailed("Input close failed: \(url.path)", underlying: error) }
        return data
    }
}
