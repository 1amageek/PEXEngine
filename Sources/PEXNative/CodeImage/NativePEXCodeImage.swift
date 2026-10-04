import Foundation
import ObjectiveC
import MachO
import Darwin
import CryptoKit
import CircuiteFoundation
import CircuiteFoundationFoundation

/// Loaded-image selection plus its UUID-matched, complete backing-file identity.
public struct NativePEXCodeImage: Sendable, Codable, Equatable {
    public let url: URL
    public let uuid: UUID
    public let byteCount: UInt64
    public let digest: ContentDigest

    public static func measure(maximumBytes: Int = 512 * 1024 * 1024) throws -> Self {
        guard maximumBytes > 0 else { throw NativePEXCodeImageError.byteLimitExceeded }
        guard let name = class_getImageName(NativePEXImageAnchor.self) else {
            throw NativePEXCodeImageError.imageUnavailable
        }
        // The runtime owns this immutable string; copy before leaving this call.
        let path = String(cString: name)
        guard let lease = dlopen(path, RTLD_NOLOAD | RTLD_LAZY) else {
            throw NativePEXCodeImageError.imageUnavailable
        }
        defer { dlclose(lease) }
        guard let header = _dyld_get_dlopen_image_header(lease), header.pointee.magic == MH_MAGIC_64 else {
            throw NativePEXCodeImageError.invalidMachO
        }
        let commandBytes = Int(header.pointee.sizeofcmds)
        guard commandBytes <= maximumBytes - min(maximumBytes, 32) else {
            throw NativePEXCodeImageError.byteLimitExceeded
        }
        // dyld owns validated, initialized read-only Mach-O metadata. The NOLOAD
        // lease keeps the image alive. Only its declared command-table span is
        // copied, no pointer escapes, and all record offsets are checked below.
        let commands = Data(bytes: UnsafeRawPointer(header).advanced(by: 32), count: commandBytes)
        let loadedUUID = try NativePEXMachOIdentity.commandUUID(commands, count: Int(header.pointee.ncmds))
        let url = URL(filePath: path)
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw NativePEXCodeImageError.fileFailure(String(describing: error)) }
        let observation: Self
        do {
            let fileUUID = try NativePEXMachOIdentity.fileUUID(handle, cpu: UInt32(bitPattern: header.pointee.cputype),
                subtype: UInt32(bitPattern: header.pointee.cpusubtype), maximumBytes: maximumBytes)
            guard fileUUID == loadedUUID else { throw NativePEXCodeImageError.uuidMismatch }
            try handle.seek(toOffset: 0)
            var hash = SHA256(), total = 0
            while let chunk = try handle.read(upToCount: min(256 * 1024, maximumBytes - total + (total == maximumBytes ? 1 : 0))), !chunk.isEmpty {
                guard chunk.count <= maximumBytes - total else { throw NativePEXCodeImageError.byteLimitExceeded }
                total += chunk.count; hash.update(data: chunk)
            }
            guard total > 0 else { throw NativePEXCodeImageError.invalidMachO }
            let digest = try ContentDigest(algorithm: .sha256, hexadecimalValue:
                hash.finalize().map { String(format: "%02x", $0) }.joined())
            observation = Self(url: url, uuid: loadedUUID, byteCount: UInt64(total), digest: digest)
        } catch {
            do { try handle.close() }
            catch let closeError { throw NativePEXCodeImageError.fileFailure("\(error); close: \(closeError)") }
            throw error
        }
        do { try handle.close() }
        catch { throw NativePEXCodeImageError.fileFailure(String(describing: error)) }
        return observation
    }

    public func verifyUnchanged(maximumBytes: Int = 512 * 1024 * 1024) throws {
        guard try Self.measure(maximumBytes: maximumBytes) == self else {
            throw NativePEXCodeImageError.changedDuringExecution
        }
    }
}
