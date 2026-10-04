import Foundation

/// Bounds-checked parsing of identity metadata; never interprets file pointers.
enum NativePEXMachOIdentity {
    static func word(_ bytes: Data, _ offset: Int, bigEndian: Bool = false) throws -> UInt32 {
        guard offset >= 0, offset <= bytes.count, bytes.count - offset >= 4 else {
            throw NativePEXCodeImageError.invalidMachO
        }
        return (0..<4).reduce(0) { value, i in
            value | UInt32(bytes[offset + i]) << UInt32((bigEndian ? 3 - i : i) * 8)
        }
    }
    static func commandUUID(_ bytes: Data, count: Int) throws -> UUID {
        guard count >= 0, count <= bytes.count / 8 else { throw NativePEXCodeImageError.invalidMachO }
        var offset = 0, uuid: UUID?
        for _ in 0..<count {
            let command = try word(bytes, offset), size = Int(try word(bytes, offset + 4))
            guard size >= 8, size % 4 == 0, size <= bytes.count - offset else { throw NativePEXCodeImageError.invalidMachO }
            if command == 0x1b {
                guard size == 24, uuid == nil else { throw NativePEXCodeImageError.invalidMachO }
                let v = Array(bytes[(offset + 8)..<(offset + 24)])
                uuid = UUID(uuid: (v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7],v[8],v[9],v[10],v[11],v[12],v[13],v[14],v[15]))
            }
            offset += size
        }
        guard offset == bytes.count, let uuid else { throw NativePEXCodeImageError.invalidMachO }
        return uuid
    }
    private static func read(_ handle: FileHandle, offset: UInt64, count: Int, maximumBytes: Int) throws -> Data {
        guard count >= 0, offset <= UInt64(maximumBytes), UInt64(count) <= UInt64(maximumBytes) - offset else {
            throw NativePEXCodeImageError.byteLimitExceeded
        }
        try handle.seek(toOffset: offset)
        var bytes = Data()
        while bytes.count < count {
            guard let chunk = try handle.read(upToCount: count - bytes.count), !chunk.isEmpty else {
                throw NativePEXCodeImageError.invalidMachO
            }
            bytes.append(chunk)
        }
        return bytes
    }
    static func fileUUID(_ handle: FileHandle, cpu: UInt32, subtype: UInt32, maximumBytes: Int) throws -> UUID {
        let initial = try read(handle, offset: 0, count: 8, maximumBytes: maximumBytes)
        let magic = try word(initial, 0, bigEndian: true)
        var offset: UInt64 = 0, sliceEnd = UInt64(maximumBytes)
        if magic == 0xcafebabe || magic == 0xcafebabf {
            let count = Int(try word(initial, 4, bigEndian: true)), stride = magic == 0xcafebabe ? 20 : 32
            guard count > 0, count <= (maximumBytes - min(maximumBytes, 8)) / stride else { throw NativePEXCodeImageError.invalidMachO }
            let table = try read(handle, offset: 8, count: count * stride, maximumBytes: maximumBytes)
            var selected: UInt64?
            for index in 0..<count {
                let start = index * stride
                guard try word(table, start, bigEndian: true) == cpu,
                      try word(table, start + 4, bigEndian: true) == subtype else { continue }
                guard selected == nil else { throw NativePEXCodeImageError.invalidMachO }
                let high = try word(table, start + 8, bigEndian: true)
                let position = stride == 20 ? UInt64(high) : UInt64(high) << 32 | UInt64(try word(table, start + 12, bigEndian: true))
                let sizeHigh = try word(table, start + (stride == 20 ? 12 : 16), bigEndian: true)
                let size = stride == 20 ? UInt64(sizeHigh) : UInt64(sizeHigh) << 32 | UInt64(try word(table, start + 20, bigEndian: true))
                guard position >= UInt64(8 + count * stride), position <= UInt64(maximumBytes), size >= 32,
                      size <= UInt64(maximumBytes) - position else { throw NativePEXCodeImageError.invalidMachO }
                selected = position; sliceEnd = position + size
            }
            guard let selected else { throw NativePEXCodeImageError.architectureMismatch }
            offset = selected
        }
        let header = try read(handle, offset: offset, count: 32, maximumBytes: maximumBytes)
        guard try word(header, 0) == 0xfeedfacf else { throw NativePEXCodeImageError.invalidMachO }
        guard try word(header, 4) == cpu, try word(header, 8) == subtype else { throw NativePEXCodeImageError.architectureMismatch }
        let size = Int(try word(header, 20)), count = Int(try word(header, 16))
        guard offset <= sliceEnd, sliceEnd - offset >= 32, UInt64(size) <= sliceEnd - offset - 32 else {
            throw NativePEXCodeImageError.invalidMachO
        }
        let commands = try read(handle, offset: offset + 32, count: size, maximumBytes: maximumBytes)
        return try commandUUID(commands, count: count)
    }
}
