import Foundation
import PEXCore

/// Maps standard tokens to canonical ownership without duplicating operator values.
struct PEXSPICEIdentity: Sendable, Codable {
    struct Node: Sendable, Codable {
        let ref: NodeRef
        let kind: NodeKind
        let instancePath: InstancePath?

        init(ref: NodeRef, kind: NodeKind, instancePath: InstancePath? = nil) {
            self.ref = ref; self.kind = kind; self.instancePath = instancePath
        }
    }

    static let marker = "* PEX_IDENTITY_V1 "
    let nodes: [String: Node]
    let elementKinds: [String: ElementKind]
    let referenceName: String
    let referenceToken: String
    /// Nil preserves the original generated annotation encoding for existing writers.
    var canonicalTerminals: Bool? = nil

    func comment() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self.marker + (try encoder.encode(self)).base64EncodedString()
    }

    static func read(_ source: String, cornerID: PEXCornerID, caseInsensitive: Bool = true) throws -> Self? {
        let lines = source.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let annotations = lines.filter { $0.hasPrefix(marker) }
        guard !annotations.isEmpty else {
            if lines.contains(where: { $0.hasPrefix("* PEX backannotation generated") }) {
                throw PEXError.parseFailed(cornerID: cornerID, message: "Generated PEX SPICE is missing its identity annotation")
            }
            return nil
        }
        guard annotations.count == 1,
              let data = Data(base64Encoded: String(annotations[0].dropFirst(marker.count))) else {
            throw PEXError.parseFailed(cornerID: cornerID, message: "Invalid PEX SPICE identity annotation")
        }
        let identity: Self
        do { identity = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw PEXError.parseFailed(cornerID: cornerID, message: "Invalid PEX SPICE identity annotation", underlying: error) }
        guard !identity.referenceName.isEmpty, !identity.referenceToken.isEmpty,
              Set(identity.nodes.keys.map { caseInsensitive ? $0.lowercased() : $0 }).count == identity.nodes.count,
              Set(identity.nodes.values.map(\.ref)).count == identity.nodes.count,
              identity.nodes.values.allSatisfy({ !$0.ref.netName.value.isEmpty && !$0.ref.nodeName.value.isEmpty }),
              !identity.nodes.keys.contains(where: { caseInsensitive ? $0.caseInsensitiveCompare(identity.referenceToken) == .orderedSame : $0 == identity.referenceToken }) else {
            throw PEXError.parseFailed(cornerID: cornerID, message: "Noninjective or inconsistent PEX SPICE identity annotation")
        }
        return identity
    }

    static func encodedToken(_ ref: NodeRef) -> String {
        "PEX_N_\(hex(ref.netName.value))_\(hex(ref.nodeName.value))"
    }

    static func hex(_ string: String) -> String {
        string.utf8.map { String(format: "%02x", $0) }.joined()
    }

    // These overloads retain the legacy Codable wire representation. The scan
    // admits our visible schema payload before Foundation's atomic codec call;
    // Foundation's private allocator workspace is outside the logical ledger.
    func comment(scope: PEXParserResourceScope) throws -> String {
        let bound = try encodedJSONBound(scope: scope)
        return try scope.withTemporaryStorage(byteCount: UInt64(bound)) {
            try scope.check(0)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data: Data
            do { data = try encoder.encode(self) }
            catch {
                throw try scope.sourceFailure(diagnosticBytes: 0) { error }
            }
            try scope.check(UInt64(data.count))
            guard data.count <= bound else { throw PEXParserResourceError.capacityOverflow }
            let base64Count = try PEXParserStorageSize.multiply(
                PEXParserStorageSize.add(data.count, 2) / 3, 4)
            return try scope.withTemporaryStorage(byteCount: UInt64(
                try PEXParserStorageSize.add(MemoryLayout<String>.stride, base64Count))) {
                let encoded = data.base64EncodedString()
                try scope.check(0)
                let resultCount = try PEXParserStorageSize.add(Self.marker.utf8.count, base64Count)
                try scope.reserve(kind: .retained, byteCount: UInt64(
                    try PEXParserStorageSize.add(MemoryLayout<String>.stride, resultCount)))
                return Self.marker + encoded
            }
        }
    }

    static func read(_ source: String, cornerID: PEXCornerID, caseInsensitive: Bool = true,
                     scope: PEXParserResourceScope) throws -> Self? {
        let count = try lineCapacity(source, scope: scope)
        return try scope.withTemporaryStorage(byteCount: UInt64(
            try PEXParserStorageSize.array(Substring.self, count: count))) {
            var annotation: Substring?
            var annotationCount = 0
            var generated = false
            for rawLine in source.split(whereSeparator: \.isNewline) {
                try scope.check()
                // Trimming is a view, so line scans need no owned String buffer.
                var line = rawLine
                while let scalar = line.unicodeScalars.first, CharacterSet.whitespaces.contains(scalar) {
                    try scope.check(); line = line[line.unicodeScalars.index(after: line.startIndex)...]
                }
                while let scalar = line.unicodeScalars.last, CharacterSet.whitespaces.contains(scalar) {
                    try scope.check(); line = line[..<line.unicodeScalars.index(before: line.endIndex)]
                }
                if line.hasPrefix(marker) {
                    annotationCount = try PEXParserStorageSize.add(annotationCount, 1)
                    annotation = line
                }
                if line.hasPrefix("* PEX backannotation generated") { generated = true }
            }
            guard let annotation else {
                if generated {
                    throw try sourceFailure("Generated PEX SPICE is missing its identity annotation",
                        cornerID: cornerID, scope: scope)
                }
                return nil
            }
            guard annotationCount == 1 else {
                throw try sourceFailure("Invalid PEX SPICE identity annotation", cornerID: cornerID, scope: scope)
            }
            let encodedView = annotation.dropFirst(marker.count)
            let encodedBytes = encodedView.utf8.count
            // Admit three bytes per quartet, including a possible partial
            // final quartet; Foundation remains the authority for acceptance.
            let decodedBound = try PEXParserStorageSize.multiply(
                PEXParserStorageSize.add(encodedBytes, 3) / 4, 3)
            let buffers = try PEXParserStorageSize.add(MemoryLayout<String>.stride,
                PEXParserStorageSize.add(encodedBytes,
                    PEXParserStorageSize.add(MemoryLayout<Data>.stride, decodedBound)))
            return try scope.withTemporaryStorage(byteCount: UInt64(buffers)) {
                let encoded = String(encodedView)
                try scope.check(UInt64(encodedBytes))
                guard let data = Data(base64Encoded: encoded) else {
                    throw try sourceFailure("Invalid PEX SPICE identity annotation", cornerID: cornerID, scope: scope)
                }
                try scope.check(0)
                guard data.count <= decodedBound else { throw PEXParserResourceError.capacityOverflow }
                try admitDecodedSchema(data, scope: scope)
                let identity: Self
                // Preserve the actual codec cause without materializing its
                // unbounded textual description on the controlled path.
                do { identity = try JSONDecoder().decode(Self.self, from: data) }
                catch { throw try scope.sourceFailure(diagnosticBytes: 0) { error } }
                try scope.check(0)
                try identity.validate(cornerID: cornerID, caseInsensitive: caseInsensitive, scope: scope)
                return identity
            }
        }
    }

    static func encodedToken(_ ref: NodeRef, scope: PEXParserResourceScope) throws -> String {
        let net = try hex(ref.netName.value, scope: scope)
        let node = try hex(ref.nodeName.value, scope: scope)
        let count = try PEXParserStorageSize.add(7,
            PEXParserStorageSize.add(net.utf8.count, node.utf8.count))
        try scope.reserve(kind: .retained, byteCount: UInt64(
            try PEXParserStorageSize.add(MemoryLayout<String>.stride, count)))
        try scope.check()
        return "PEX_N_\(net)_\(node)"
    }

    static func hex(_ string: String, scope: PEXParserResourceScope) throws -> String {
        let count = try PEXParserStorageSize.multiply(string.utf8.count, 2)
        let scratch = try PEXParserStorageSize.array(UInt8.self, count: count)
        return try scope.withTemporaryStorage(byteCount: UInt64(scratch)) {
            try scope.reserve(kind: .retained, byteCount: UInt64(
                try PEXParserStorageSize.add(MemoryLayout<String>.stride, count)))
            var bytes: [UInt8] = []
            bytes.reserveCapacity(count)
            for byte in string.utf8 {
                try scope.check()
                let high = byte >> 4, low = byte & 15
                bytes.append(high < 10 ? high + 48 : high + 87)
                bytes.append(low < 10 ? low + 48 : low + 87)
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    static func lineCapacity(_ source: String, scope: PEXParserResourceScope) throws -> Int {
        var count = 1
        for character in source {
            try scope.check()
            if character.isNewline { count = try PEXParserStorageSize.add(count, 1) }
        }
        return count
    }

    private func validate(cornerID: PEXCornerID, caseInsensitive: Bool,
                          scope: PEXParserResourceScope) throws {
        let count = nodes.count
        let bytes = try PEXParserStorageSize.add(
            PEXParserStorageSize.add(MemoryLayout<Set<String>>.stride,
                PEXParserStorageSize.multiply(count, MemoryLayout<String>.stride)),
            PEXParserStorageSize.add(MemoryLayout<Set<NodeRef>>.stride,
                PEXParserStorageSize.multiply(count, MemoryLayout<NodeRef>.stride)))
        try scope.withTemporaryStorage(byteCount: UInt64(bytes)) {
            var tokens: Set<String> = [], refs: Set<NodeRef> = []
            tokens.reserveCapacity(count); refs.reserveCapacity(count)
            var valid = !referenceName.isEmpty && !referenceToken.isEmpty
            for (key, node) in nodes {
                try scope.check()
                let canonical = caseInsensitive
                    ? try PEXParserTextSizing.lowercased(key, kind: .temporary, scope: scope) : key
                valid = tokens.insert(canonical).inserted && valid
                valid = refs.insert(node.ref).inserted && valid
                valid = !node.ref.netName.value.isEmpty && !node.ref.nodeName.value.isEmpty && valid
                let isReference = caseInsensitive
                    ? key.caseInsensitiveCompare(referenceToken) == .orderedSame : key == referenceToken
                valid = !isReference && valid
            }
            guard valid else {
                throw try Self.sourceFailure("Noninjective or inconsistent PEX SPICE identity annotation",
                    cornerID: cornerID, scope: scope)
            }
        }
    }

    private static func admitDecodedSchema(_ data: Data, scope: PEXParserResourceScope) throws {
        // Escapes never expand beyond their counted decoded-code-unit envelope.
        // Every stored schema dictionary entry owns at most a String/Node pair. Counting
        // all keys (including ignored unknown fields) is conservative without
        // imposing a new JSON acceptance grammar or a nesting-depth restriction.
        var width = 1, littleEndian = false, offset = 0
        // Foundation JSON may recognize UTF-16/32 as well as UTF-8. Count
        // decoded scalar payload from code units, without creating a text copy
        // or narrowing the decoder's accepted encoding set.
        if data.count >= 4 {
            let a = data[0], b = data[1], c = data[2], d = data[3]
            if a == 0 && b == 0 && c == 0xFE && d == 0xFF { width = 4; offset = 4 }
            else if a == 0xFF && b == 0xFE && c == 0 && d == 0 { width = 4; littleEndian = true; offset = 4 }
            else if a == 0 && b == 0 && c == 0 { width = 4 }
            else if b == 0 && c == 0 && d == 0 { width = 4; littleEndian = true }
            else if a == 0xFE && b == 0xFF { width = 2; offset = 2 }
            else if a == 0xFF && b == 0xFE { width = 2; littleEndian = true; offset = 2 }
            else if a == 0 && c == 0 { width = 2 }
            else if b == 0 && d == 0 { width = 2; littleEndian = true }
        }
        var strings = 0, stringBytes = 0, members = 0
        var inString = false, escaped = false
        while offset < data.count {
            try scope.check()
            var unit: UInt32 = 0
            let available = min(width, data.count - offset)
            for index in 0..<available {
                let shift = littleEndian ? index * 8 : (available - index - 1) * 8
                unit |= UInt32(data[offset + index]) << shift
            }
            offset += available
            let utf8Bytes = width == 1 ? 1 : unit <= 0x7F ? 1 : unit <= 0x7FF ? 2 : unit <= 0xFFFF ? 3 : 4
            if inString {
                if escaped { escaped = false; stringBytes = try PEXParserStorageSize.add(stringBytes, utf8Bytes) }
                else if unit == 92 { escaped = true; stringBytes = try PEXParserStorageSize.add(stringBytes, utf8Bytes) }
                else if unit == 34 { inString = false }
                else { stringBytes = try PEXParserStorageSize.add(stringBytes, utf8Bytes) }
            } else if unit == 34 {
                inString = true; strings = try PEXParserStorageSize.add(strings, 1)
            } else if unit == 58 { members = try PEXParserStorageSize.add(members, 1) }
        }
        let text = try PEXParserStorageSize.add(stringBytes,
            PEXParserStorageSize.multiply(strings, MemoryLayout<String>.stride))
        let maps = try PEXParserStorageSize.add(
            PEXParserStorageSize.dictionary(String.self, Node.self, count: members),
            PEXParserStorageSize.dictionary(String.self, ElementKind.self, count: members))
        try scope.reserve(kind: .retained, byteCount: UInt64(
            try PEXParserStorageSize.add(MemoryLayout<Self>.stride, PEXParserStorageSize.add(text, maps))))
    }

    private func encodedJSONBound(scope: PEXParserResourceScope) throws -> Int {
        func string(_ value: String) throws -> Int {
            var count = 2
            for scalar in value.unicodeScalars {
                try scope.check()
                // JSON permits UTF-8 or escaped UTF-16; admit either legal
                // Foundation spelling, including surrogate pairs and slashes.
                count = try PEXParserStorageSize.add(count, scalar.value > 0xFFFF ? 12 : 6)
            }
            return count
        }
        var count = #"{"nodes":{},"elementKinds":{},"referenceName":"","referenceToken":""}"#.utf8.count
        count = try PEXParserStorageSize.add(count, string(referenceName) - 2)
        count = try PEXParserStorageSize.add(count, string(referenceToken) - 2)
        if canonicalTerminals != nil {
            count = try PEXParserStorageSize.add(count, #", "canonicalTerminals":false"#.utf8.count)
        }
        for (key, node) in nodes {
            try scope.check()
            var entry = try PEXParserStorageSize.add(string(key), 2) // Colon and possible comma.
            entry = try PEXParserStorageSize.add(entry,
                #"{"ref":{"netName":{"value":""},"nodeName":{"value":""}},"kind":""}"#.utf8.count)
            entry = try PEXParserStorageSize.add(entry, string(node.ref.netName.value) - 2)
            entry = try PEXParserStorageSize.add(entry, string(node.ref.nodeName.value) - 2)
            entry = try PEXParserStorageSize.add(entry, string(node.kind.rawValue) - 2)
            if let path = node.instancePath {
                entry = try PEXParserStorageSize.add(entry, #", "instancePath":{"value":""}"#.utf8.count)
                entry = try PEXParserStorageSize.add(entry, string(path.value) - 2)
            }
            count = try PEXParserStorageSize.add(count, entry)
        }
        for (key, kind) in elementKinds {
            try scope.check()
            count = try PEXParserStorageSize.add(count,
                PEXParserStorageSize.add(2, PEXParserStorageSize.add(string(key), string(kind.rawValue))))
        }
        // Sorted-key traversal may retain the complete dictionary key lists.
        let keys = try PEXParserStorageSize.add(
            PEXParserStorageSize.array(String.self, count: nodes.count),
            PEXParserStorageSize.array(String.self, count: elementKinds.count))
        try scope.reserve(kind: .temporary, byteCount: UInt64(keys))
        return try PEXParserStorageSize.add(MemoryLayout<Data>.stride, count)
    }


    private static func sourceFailure(_ message: String, cornerID: PEXCornerID,
                                      scope: PEXParserResourceScope) throws -> PEXParserSourceFailure {
        try scope.sourceFailure(diagnosticBytes:
            PEXParserStorageSize.add(MemoryLayout<String>.stride, message.utf8.count)) {
                PEXError.parseFailed(cornerID: cornerID, message: message)
            }
    }

}
