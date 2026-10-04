import Foundation
import PEXCore

public struct PEXBoundedInputReader: Sendable {
    public init() {}

    public func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0, url.isFileURL else {
            throw PEXError.invalidInput("Bounded input requires a local file and positive byte ceiling")
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw PEXError.invalidInput("Native input is not a regular file: \(url.path)")
            }
            let handle = try FileHandle(forReadingFrom: url)
            let data: Data
            do {
                var buffer = Data()
                while true {
                    // One excess byte detects growth/oversize without loading the whole file.
                    let remaining = maximumBytes - buffer.count
                    let count = remaining >= 256 * 1024 ? 256 * 1024 : remaining + 1
                    guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                    guard chunk.count <= remaining else {
                        throw PEXError.invalidInput("Native input exceeds byte ceiling: \(url.path)")
                    }
                    buffer.append(chunk)
                }
                data = buffer
            } catch {
                do { try handle.close() }
                catch let closeError {
                    throw PEXError.persistenceFailed("Native input read and close failed: \(error); \(closeError)")
                }
                throw error
            }
            try handle.close()
            return data
        } catch let error as PEXError { throw error }
        catch { throw PEXError.persistenceFailed("Failed to read native input: \(url.path)", underlying: error) }
    }
}
