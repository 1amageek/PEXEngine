import Foundation
import Testing
import PEXCore
import PEXPersistence

@Suite("Bounded native file read", .timeLimit(.minutes(1)))
struct PEXBoundedInputReaderTests {
    @Test func readsMultipleChunksAndRejectsExcessMissingAndDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "bounded-native-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let file = root.appending(path: "input.bin"), data = Data(repeating: 37, count: 600_000)
        try data.write(to: file)
        #expect(try PEXBoundedInputReader().read(file, maximumBytes: data.count) == data)
        #expect(throws: PEXError.self) { try PEXBoundedInputReader().read(file, maximumBytes: data.count - 1) }
        #expect(throws: PEXError.self) { try PEXBoundedInputReader().read(file, maximumBytes: 0) }
        #expect(throws: PEXError.self) { try PEXBoundedInputReader().read(root, maximumBytes: 10) }
        #expect(throws: PEXError.self) { try PEXBoundedInputReader().read(root.appending(path: "missing"), maximumBytes: 10) }
    }
}
