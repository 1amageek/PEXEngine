import Foundation
import CryptoKit
import Testing
@testable import PEXNative

@Suite("Actual loaded native implementation backing identity", .timeLimit(.minutes(1)))
struct NativePEXCodeImageTests {
    @Test func loadedImageHasMeasuredBackingDigestAndStableUUID() throws {
        let image = try NativePEXCodeImage.measure()
        #expect(image.url.isFileURL && image.byteCount > 0)
        let bytes = try Data(contentsOf: image.url, options: .mappedIfSafe)
        #expect(UInt64(bytes.count) == image.byteCount)
        #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == image.digest.hexadecimalValue)
        try image.verifyUnchanged()
        #expect(throws: NativePEXCodeImageError.byteLimitExceeded) { try NativePEXCodeImage.measure(maximumBytes: 1) }
    }
    @Test func malformedCommandTablesAreRejectedWithoutUncheckedOffsets() throws {
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        var bytes = Data([0x1b,0,0,0,24,0,0,0]); withUnsafeBytes(of: uuid.uuid) { bytes.append(contentsOf: $0) }
        #expect(try NativePEXMachOIdentity.commandUUID(bytes, count: 1) == uuid)
        for (data, count) in [(Data(bytes.dropLast()),1), (bytes,2), (bytes + bytes,2), (bytes + Data([0]),1),
                              (Data([0x1b,0,0,0,255,255,255,255]),1), (Data(),0)] {
            #expect(throws: NativePEXCodeImageError.invalidMachO) { try NativePEXMachOIdentity.commandUUID(data, count: count) }
        }
    }
    @Test func backingHeaderChecksArchitectureAndUniversalSliceBounds() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "native-image-header-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Cleanup: \(error)") } }
        let path = root.appending(path: "image")
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        var commands = Data([0x1b,0,0,0,24,0,0,0]); withUnsafeBytes(of: uuid.uuid) { commands.append(contentsOf: $0) }
        var thin = Data([0xcf,0xfa,0xed,0xfe,12,0,0,1,0,0,0,0,2,0,0,0,1,0,0,0,24,0,0,0,0,0,0,0,0,0,0,0]); thin.append(commands)
        func read(_ bytes: Data, cpu: UInt32 = 0x0100000c, maximum: Int = 1024) throws -> UUID {
            try bytes.write(to: path)
            let handle = try FileHandle(forReadingFrom: path)
            do { let result = try NativePEXMachOIdentity.fileUUID(handle, cpu: cpu, subtype: 0, maximumBytes: maximum)
                try handle.close(); return result }
            catch { try handle.close(); throw error }
        }
        #expect(try read(thin) == uuid)
        #expect(throws: NativePEXCodeImageError.architectureMismatch) { try read(thin, cpu: 7) }
        #expect(throws: NativePEXCodeImageError.invalidMachO) { try read(thin, maximum: 32) }
        var fat = Data([0xca,0xfe,0xba,0xbe,0,0,0,1,1,0,0,12,0,0,0,0,0,0,0,28,0,0,0,56,0,0,0,0]); fat.append(thin)
        #expect(try read(fat) == uuid)
        var clipped = fat; clipped[23] = 32
        #expect(throws: NativePEXCodeImageError.invalidMachO) { try read(clipped) }
        fat[19] = 250
        #expect(throws: NativePEXCodeImageError.self) { try read(fat) }
    }
}
