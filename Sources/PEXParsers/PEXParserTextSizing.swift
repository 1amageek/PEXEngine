/// Explicit String payload sizing for the fixed standard-library case mapping.
enum PEXParserTextSizing {
    static func caseMappedByteCount(_ text: String, uppercase: Bool,
                                   scope: PEXParserResourceScope) throws -> Int {
        let scratch = UInt64(UInt8.max) + UInt64(MemoryLayout<String>.stride)
        return try scope.withTemporaryStorage(byteCount: scratch) {
            var bytes = 0
            for scalar in text.unicodeScalars {
                try scope.check()
                let mapping = uppercase ? scalar.properties.uppercaseMapping : scalar.properties.lowercaseMapping
                let count = mapping.utf8.count
                guard count <= Int(UInt8.max) else { throw PEXParserResourceError.capacityOverflow }
                bytes = try PEXParserStorageSize.add(bytes, count)
            }
            return bytes
        }
    }

    static func lowercased(_ text: String, kind: PEXParserStorageKind,
                          scope: PEXParserResourceScope) throws -> String {
        try convert(text, uppercase: false, kind: kind, scope: scope)
    }

    static func uppercased(_ text: String, kind: PEXParserStorageKind,
                          scope: PEXParserResourceScope) throws -> String {
        try convert(text, uppercase: true, kind: kind, scope: scope)
    }

    private static func convert(_ text: String, uppercase: Bool, kind: PEXParserStorageKind,
                                scope: PEXParserResourceScope) throws -> String {
        let count = try caseMappedByteCount(text, uppercase: uppercase, scope: scope)
        // The standard implementation starts with input capacity and may grow
        // to the complete mapped payload. Both logical buffers coexist at growth.
        let capacity = try PEXParserStorageSize.add(MemoryLayout<String>.stride,
            PEXParserStorageSize.add(text.utf8.count, count))
        try scope.reserve(kind: kind, byteCount: UInt64(capacity))
        try scope.check(UInt64(text.unicodeScalars.count))
        let result = uppercase ? text.uppercased() : text.lowercased()
        try scope.check(0)
        guard result.utf8.count == count else { throw PEXParserResourceError.capacityOverflow }
        return result
    }
}
