import Foundation
import PEXCore

/// Parses the parasitic SPICE netlist produced by Magic's `ext2spice` into the
/// canonical `ParasiticIR`.
///
/// Magic emits parasitic capacitors as `C<id> <nodeA> <nodeB> <value>` and, when
/// resistance extraction is enabled, resistors as `R<id> <nodeA> <nodeB> <value>`.
/// Some extracted SPICE/DSPF producers also emit inductors as
/// `L<id> <nodeA> <nodeB> <value>`, which are retained in the canonical IR when
/// full RC extraction is requested.
/// A capacitor whose second node is the substrate/global-ground node becomes a
/// grounded `capacitor` (nodeB == nil); a capacitor between two signal nets
/// becomes a `coupling` element. Device lines (`X`/`M`/...) and directives are
/// ignored — only parasitics are lowered. Each distinct signal node is its own
/// single-node net, which satisfies `ParasiticIRValidator`'s membership rules.
public struct MagicSPICEParasiticParser: PEXParsing {

    public let format: PEXOutputFormat = .spice

    /// Node names treated as the global ground / substrate (a capacitor to one of
    /// these is a grounded capacitor, not coupling). Matched case-insensitively.
    /// Intentionally narrow: it holds only the substrate / global-ground node, not
    /// design ground rails like Sky130's `VGND`/`VPWR`, which are real nets whose
    /// capacitors must stay coupling.
    public let groundNodes: Set<String>

    public init(groundNodes: Set<String> = ["VSUBS", "0", "gnd!"]) {
        self.groundNodes = Set(groundNodes.map { $0.lowercased() })
    }

    private func isGround(_ node: String) -> Bool {
        groundNodes.contains(node.lowercased())
    }

    public func parse(_ raw: PEXRawOutput, context: PEXParseContext) throws -> ParasiticIR {
        try parse(raw, context: context, scope: nil)
    }

    public func parse(_ raw: PEXRawOutput, context: PEXParseContext,
                      control: any PEXParserResourceControlling) throws
        -> (value: ParasiticIR, retention: PEXParserRetention) {
        let scope = try PEXParserResourceScope(control: control)
        let value = try parse(raw, context: context, scope: scope)
        return (value, scope.retention)
    }

    private func parse(_ raw: PEXRawOutput, context: PEXParseContext,
                       scope: PEXParserResourceScope?) throws -> ParasiticIR {
        try scope?.check(0)
        try validateFormat(raw.format, context: context, scope: scope)
        let fileURL = try selectedFile(from: raw, context: context, scope: scope)
        let source = try readSource(from: fileURL, context: context, scope: scope)
        let lineCount: Int
        if let scope {
            lineCount = try PEXSPICEIdentity.lineCapacity(source, scope: scope)
            try scope.reserve(kind: .temporary, byteCount: UInt64(
                try PEXParserStorageSize.array(Substring.self, count: lineCount)))
        } else { lineCount = 0 }
        let identity: PEXSPICEIdentity?
        if let scope { identity = try PEXSPICEIdentity.read(source, cornerID: context.cornerID, scope: scope) }
        else { identity = try PEXSPICEIdentity.read(source, cornerID: context.cornerID) }
        if let identity {
            var records: [PEXStandardIdentityLowering.Record] = []
            if let scope {
                try scope.reserve(kind: .temporary, byteCount: UInt64(
                    try PEXParserStorageSize.array(PEXStandardIdentityLowering.Record.self, count: lineCount)))
                records.reserveCapacity(lineCount)
            }
            for rawLine in source.split(whereSeparator: \.isNewline) {
                try scope?.check()
                let tokens = try tokenize(rawLine, scope: scope)
                guard let id = tokens.first, let kind = identity.elementKinds[id] else {
                    if let first = tokens.first?.first, try elementKind(first, scope: scope) != nil {
                        throw try failure("Unmapped generated parasitic element".utf8.count, context: context, scope: scope) {
                            "Unmapped generated parasitic element"
                        }
                    }
                    continue
                }
                guard let line = try parseElementLine(try ownedText(rawLine, kind: .temporary, scope: scope), context: context, scope: scope) else {
                    throw try failure("Invalid generated parasitic element".utf8.count, context: context, scope: scope) {
                            "Invalid generated parasitic element"
                        }
                }
                let expectedPrefix = kind == .resistor ? "R" : kind == .inductor ? "L" : "C"
                guard id.hasPrefix(expectedPrefix),
                      line.nodeA != identity.referenceToken,
                      (line.nodeB != identity.referenceToken || kind == .capacitor) else {
                    throw try failure("Invalid generated parasitic reference or kind".utf8.count, context: context, scope: scope) {
                            "Invalid generated parasitic reference or kind"
                        }
                }
                if let scope {
                    try scope.reserve(kind: .retained, byteCount: UInt64(
                        try PEXParserStorageSize.add(MemoryLayout<String>.stride, id.utf8.count)))
                }
                records.append(.init(id: id, kind: kind, nodeA: line.nodeA,
                    nodeB: line.nodeB == identity.referenceToken ? nil : line.nodeB, value: line.value))
            }
            if let scope {
                return try PEXStandardIdentityLowering.lower(records, identity: identity,
                    context: context, sourceFormat: "pex-spice", scope: scope)
            }
            return try PEXStandardIdentityLowering.lower(records, identity: identity, context: context, sourceFormat: "pex-spice")
        }
        let records = try parseRecords(source: source, context: context, lineCount: lineCount, scope: scope)
        if let scope {
            // Foundation owns this NUL-terminated filesystem representation for
            // this closure only. The pointer never escapes, is read without
            // mutation, and has no manual allocation or deallocation. Its UTF-8
            // path length bounds the derived final path-component payload.
            let pathBytes = try fileURL.withUnsafeFileSystemRepresentation { pointer in
                guard let pointer else { throw PEXParserResourceError.capacityOverflow }
                var count = 0
                while pointer[count] != 0 {
                    try scope.check()
                    count = try PEXParserStorageSize.add(count, 1)
                }
                return count
            }
            try scope.reserve(kind: .retained, byteCount: UInt64(
                try PEXParserStorageSize.add(MemoryLayout<String>.stride, pathBytes)))
        }
        return try buildIR(
            records: records,
            sourceFileName: fileURL.lastPathComponent,
            context: context, scope: scope
        )
    }

    private func readControlledSource(from fileURL: URL, context: PEXParseContext,
                                      scope: PEXParserResourceScope) throws -> String {
        func io<Result>(_ body: () throws -> Result) throws -> Result {
            do { return try body() }
            catch { throw try scope.sourceFailure(diagnosticBytes: 0) { error } }
        }
        try scope.check(0)
        let handle = try io { try FileHandle(forReadingFrom: fileURL) }
        var data = Data()
        do {
            let length = try io { try handle.seekToEnd() }
            try io { try handle.seek(toOffset: 0) }
            guard let size = Int(exactly: length) else {
                throw PEXParserResourceError.capacityOverflow
            }
            let probeSize = try PEXParserStorageSize.add(size, 1)
            // One file buffer, its possible append replacement, and a bounded
            // read chunk coexist. A one-byte probe detects growth without
            // allowing the admitted file buffer to grow beyond its original size.
            let chunkSize = min(probeSize, 65_536)
            let dataBytes = try PEXParserStorageSize.add(
                PEXParserStorageSize.multiply(size, 2), chunkSize)
            try scope.reserve(kind: .temporary, byteCount: UInt64(
                try PEXParserStorageSize.add(dataBytes, 2 * MemoryLayout<Data>.stride)))
            data.reserveCapacity(size)
            while true {
                try scope.check()
                let remaining = try PEXParserStorageSize.add(size - data.count, 1)
                let chunk = try io { try handle.read(upToCount: min(chunkSize, remaining)) ?? Data() }
                try scope.check(UInt64(chunk.count))
                if chunk.isEmpty { break }
                guard chunk.count <= size - data.count else {
                    throw PEXParserResourceError.capacityOverflow
                }
                data.append(chunk)
            }
            try io { try handle.close() }
        } catch {
            // Closing never masks a cancellation, capacity, or read failure.
            do { try handle.close() } catch { /* The primary operation owns failure. */ }
            throw error
        }
        try scope.reserve(kind: .retained, byteCount: UInt64(
            try PEXParserStorageSize.add(MemoryLayout<String>.stride, data.count)))
        try scope.check(0)
        guard let source = String(data: data, encoding: .utf8) else {
            throw try scope.sourceFailure(diagnosticBytes: 0) {
                CocoaError(.fileReadInapplicableStringEncoding)
            }
        }
        try scope.check(0)
        return source
    }

    private func ownedText(_ value: Substring, kind: PEXParserStorageKind,
                           scope: PEXParserResourceScope?) throws -> String {
        if let scope {
            try scope.check(UInt64(value.utf8.count))
            try scope.reserve(kind: kind, byteCount: UInt64(
                try PEXParserStorageSize.add(MemoryLayout<String>.stride, value.utf8.count)))
        }
        return String(value)
    }

    private func elementKind(_ first: Character, scope: PEXParserResourceScope?) throws -> MagicSPICEElementKind? {
        guard let scope else { return MagicSPICEElementKind(rawPrefix: first) }
        // Each extended grapheme's source UTF-8 count is known before copying.
        var bytes = 0
        for scalar in first.unicodeScalars {
            try scope.check()
            let value = scalar.value
            bytes = try PEXParserStorageSize.add(bytes,
                value <= 0x7F ? 1 : value <= 0x7FF ? 2 : value <= 0xFFFF ? 3 : 4)
        }
        try scope.reserve(kind: .temporary, byteCount: UInt64(
            try PEXParserStorageSize.add(MemoryLayout<String>.stride, bytes)))
        let lowered = try PEXParserTextSizing.lowercased(String(first), kind: .temporary, scope: scope)
        switch lowered {
        case "c": return .capacitor
        case "r": return .resistor
        case "l": return .inductor
        default: return nil
        }
    }

    private func tokenize(_ line: Substring, scope: PEXParserResourceScope?) throws -> [String] {
        guard let scope else { return line.split(whereSeparator: \.isWhitespace).map(String.init) }
        var count = 0, inToken = false
        for character in line {
            try scope.check()
            if character.isWhitespace { inToken = false }
            else if !inToken { count = try PEXParserStorageSize.add(count, 1); inToken = true }
        }
        let slots = try PEXParserStorageSize.add(
            PEXParserStorageSize.array(Substring.self, count: count),
            PEXParserStorageSize.array(String.self, count: count))
        try scope.reserve(kind: .temporary, byteCount: UInt64(slots))
        var result: [String] = []
        result.reserveCapacity(count)
        for token in line.split(whereSeparator: \.isWhitespace) {
            result.append(try ownedText(token, kind: .temporary, scope: scope))
        }
        return result
    }

    private func failure(_ bytes: Int, context: PEXParseContext,
                         scope: PEXParserResourceScope?, _ message: () -> String) throws -> any Error {
        if let scope {
            return try scope.sourceFailure(diagnosticBytes:
                PEXParserStorageSize.add(MemoryLayout<String>.stride, bytes)) {
                    PEXError.parseFailed(cornerID: context.cornerID, message: message())
                }
        }
        return PEXError.parseFailed(cornerID: context.cornerID, message: message())
    }

    private func validateFormat(_ rawFormat: PEXOutputFormat, context: PEXParseContext,
                                scope: PEXParserResourceScope?) throws {
        guard rawFormat == format else {
            throw try failure(PEXParserStorageSize.add(
                "Magic SPICE parser received raw output format ''".utf8.count, rawFormat.rawValue.utf8.count),
                context: context, scope: scope) {
                    "Magic SPICE parser received raw output format '\(rawFormat.rawValue)'"
                }
        }
    }

    private func selectedFile(from raw: PEXRawOutput, context: PEXParseContext,
                              scope: PEXParserResourceScope?) throws -> URL {
        guard let fileURL = raw.fileURLs.first else {
            throw try failure("No SPICE file found in raw output".utf8.count, context: context, scope: scope) {
                "No SPICE file found in raw output"
            }
        }
        return fileURL
    }

    private func readSource(from fileURL: URL, context: PEXParseContext,
                            scope: PEXParserResourceScope?) throws -> String {
        if let scope { return try readControlledSource(from: fileURL, context: context, scope: scope) }
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "Failed to read SPICE file: \(fileURL.lastPathComponent)",
                underlying: error
            )
        }
    }

    private func parseRecords(source: String, context: PEXParseContext, lineCount: Int,
                              scope: PEXParserResourceScope?) throws -> MagicSPICERecords {
        let options = context.options
        var records = MagicSPICERecords()
        if let scope { try records.prepare(lineCount: lineCount, scope: scope) }
        for rawLine in source.split(whereSeparator: \.isNewline) {
            if let line = try parseElementLine(try ownedText(rawLine, kind: .temporary, scope: scope), context: context, scope: scope) {
                try append(line, to: &records, options: options, scope: scope)
            }
        }
        return records
    }

    private func parseElementLine(_ rawLine: String, context: PEXParseContext,
                                  scope: PEXParserResourceScope? = nil) throws -> MagicSPICEElementLine? {
        try scope?.check(UInt64(rawLine.utf8.count))
        if let scope {
            try scope.reserve(kind: .temporary, byteCount: UInt64(
                try PEXParserStorageSize.add(MemoryLayout<String>.stride, rawLine.utf8.count)))
        }
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard let first = line.first else { return nil }
        if first == "*" || first == "." || first == "+" { return nil }
        let tokens = try tokenize(line[...], scope: scope)
        guard let kind = try elementKind(first, scope: scope) else { return nil }
        guard let elementTokens = MagicSPICEElementTokens(tokens: tokens) else {
            let bytes = try PEXParserStorageSize.add(line.utf8.count,
                PEXParserStorageSize.add(kind.rawName.utf8.count,
                    "Truncated  element line requires name, two nodes, and value: ".utf8.count))
            throw try failure(bytes, context: context, scope: scope) {
                "Truncated \(kind.rawName) element line requires name, two nodes, and value: \(line)"
            }
        }
        let parsedValue: Double?
        if let scope { parsedValue = try Self.parseSPICEValue(elementTokens.valueToken, scope: scope) }
        else { parsedValue = Self.parseSPICEValue(elementTokens.valueToken) }
        guard let value = parsedValue else {
            let bytes = try PEXParserStorageSize.add(line.utf8.count,
                PEXParserStorageSize.add(elementTokens.valueToken.utf8.count,
                    "Unparseable value '' in line: ".utf8.count))
            throw try failure(bytes, context: context, scope: scope) {
                "Unparseable value '\(elementTokens.valueToken)' in line: \(line)"
            }
        }

        return MagicSPICEElementLine(
            kind: kind,
            nodeA: elementTokens.nodeA,
            nodeB: elementTokens.nodeB,
            value: value
        )
    }

    private func append(
        _ line: MagicSPICEElementLine,
        to records: inout MagicSPICERecords,
        options: PEXRunOptions,
        scope: PEXParserResourceScope?
    ) throws {
        try scope?.check()
        switch line.kind {
        case .capacitor:
            try appendCapacitor(line, to: &records, options: options, scope: scope)
        case .resistor:
            try records.connectivity.see(line.nodeA, scope: scope)
            try records.connectivity.see(line.nodeB, scope: scope)
            try records.connectivity.union(line.nodeA, line.nodeB, scope: scope)
            guard shouldIncludeResistance(line.value, options: options) else { return }
            records.resistors.append(MagicPairRecord(a: line.nodeA, b: line.nodeB, value: line.value))
        case .inductor:
            try records.connectivity.see(line.nodeA, scope: scope)
            try records.connectivity.see(line.nodeB, scope: scope)
            try records.connectivity.union(line.nodeA, line.nodeB, scope: scope)
            guard shouldIncludeInductance(options: options) else { return }
            records.inductors.append(MagicPairRecord(a: line.nodeA, b: line.nodeB, value: line.value))
        }
    }

    private func appendCapacitor(
        _ line: MagicSPICEElementLine,
        to records: inout MagicSPICERecords,
        options: PEXRunOptions,
        scope: PEXParserResourceScope?
    ) throws {
        let aGround: Bool, bGround: Bool
        if let scope {
            aGround = groundNodes.contains(try PEXParserTextSizing.lowercased(line.nodeA, kind: .temporary, scope: scope))
            bGround = groundNodes.contains(try PEXParserTextSizing.lowercased(line.nodeB, kind: .temporary, scope: scope))
        } else { aGround = isGround(line.nodeA); bGround = isGround(line.nodeB) }
        if aGround && bGround { return }
        if aGround || bGround {
            let signal = aGround ? line.nodeB : line.nodeA
            try records.connectivity.see(signal, scope: scope)
            guard shouldIncludeCapacitance(line.value, options: options) else { return }
            records.grounds.append(MagicGroundCapRecord(signal: signal, value: line.value))
        } else {
            try records.connectivity.see(line.nodeA, scope: scope)
            try records.connectivity.see(line.nodeB, scope: scope)
            guard options.includeCouplingCaps else { return }
            guard shouldIncludeCapacitance(line.value, options: options) else { return }
            records.couplings.append(MagicPairRecord(a: line.nodeA, b: line.nodeB, value: line.value))
        }
    }

    private func buildIR(
        records: MagicSPICERecords,
        sourceFileName: String,
        context: PEXParseContext,
        scope: PEXParserResourceScope?
    ) throws -> ParasiticIR {
        let netNameOf = try records.connectivity.netNameMap(scope: scope)
        let nodeOrder = records.connectivity.nodeOrder
        if let scope {
            for node in nodeOrder {
                try scope.check()
                try scope.reserve(kind: .retained, byteCount: UInt64(
                    try PEXParserStorageSize.add(MemoryLayout<String>.stride, node.utf8.count)))
            }
        }

        var elements: [ParasiticElement] = []
        var capIndex = 0
        var resIndex = 0
        var indIndex = 0
        var groundCap: [String: Double] = [:]
        var couplingCap: [String: Double] = [:]
        var resistance: [String: Double] = [:]
        if let scope {
            let count = try PEXParserStorageSize.add(records.grounds.count,
                PEXParserStorageSize.add(records.couplings.count,
                    PEXParserStorageSize.add(records.resistors.count, records.inductors.count)))
            try scope.reserve(kind: .retained, byteCount: UInt64(
                try PEXParserStorageSize.array(ParasiticElement.self, count: count)))
            elements.reserveCapacity(count)
            let maps = try PEXParserStorageSize.dictionary(String.self, Double.self, count: nodeOrder.count)
            try scope.reserve(kind: .temporary, byteCount: UInt64(try PEXParserStorageSize.multiply(maps, 3)))
            groundCap.reserveCapacity(nodeOrder.count); couplingCap.reserveCapacity(nodeOrder.count)
            resistance.reserveCapacity(nodeOrder.count)
        }

        func netName(_ n: String) -> String { netNameOf[n] ?? n }
        func nodeRef(_ n: String) -> NodeRef {
            NodeRef(netName: NetName(netName(n)), nodeName: NodeName(n))
        }

        for g in records.grounds {
            try scope?.check()
            if let scope {
                // The binary width bounds the decimal digit count of any nonnegative Int.
                let idBytes = 1 + Int.bitWidth
                try scope.reserve(kind: .retained, byteCount: UInt64(MemoryLayout<String>.stride + idBytes))
            }
            elements.append(ParasiticElement(
                id: "C\(capIndex)", kind: .capacitor,
                nodeA: nodeRef(g.signal), nodeB: nil, value: g.value, source: .extracted
            ))
            capIndex += 1
            groundCap[netName(g.signal), default: 0] += g.value
        }
        for c in records.couplings {
            try scope?.check()
            if let scope {
                // The binary width bounds the decimal digit count of any nonnegative Int.
                let idBytes = 1 + Int.bitWidth
                try scope.reserve(kind: .retained, byteCount: UInt64(MemoryLayout<String>.stride + idBytes))
            }
            elements.append(ParasiticElement(
                id: "C\(capIndex)", kind: .coupling,
                nodeA: nodeRef(c.a), nodeB: nodeRef(c.b), value: c.value, source: .extracted
            ))
            capIndex += 1
            // Attribute coupling to one net only (a's net), matching SPEFLowering.
            couplingCap[netName(c.a), default: 0] += c.value
        }
        for r in records.resistors {
            try scope?.check()
            if let scope {
                // The binary width bounds the decimal digit count of any nonnegative Int.
                let idBytes = 1 + Int.bitWidth
                try scope.reserve(kind: .retained, byteCount: UInt64(MemoryLayout<String>.stride + idBytes))
            }
            elements.append(ParasiticElement(
                id: "R\(resIndex)", kind: .resistor,
                nodeA: nodeRef(r.a), nodeB: nodeRef(r.b), value: r.value, source: .extracted
            ))
            resIndex += 1
            // Count the resistor once (on a's net), matching SPEFLowering.
            resistance[netName(r.a), default: 0] += r.value
        }
        for l in records.inductors {
            try scope?.check()
            if let scope {
                // The binary width bounds the decimal digit count of any nonnegative Int.
                let idBytes = 1 + Int.bitWidth
                try scope.reserve(kind: .retained, byteCount: UInt64(MemoryLayout<String>.stride + idBytes))
            }
            elements.append(ParasiticElement(
                id: "L\(indIndex)", kind: .inductor,
                nodeA: nodeRef(l.a), nodeB: nodeRef(l.b), value: l.value, source: .extracted
            ))
            indIndex += 1
        }

        // Nets and their nodes retain the original first-seen ordering.
        if let scope {
            let arrays = try PEXParserStorageSize.array(String.self, count: nodeOrder.count)
            let set = try PEXParserStorageSize.add(MemoryLayout<Set<String>>.stride,
                PEXParserStorageSize.multiply(nodeOrder.count, MemoryLayout<String>.stride))
            try scope.reserve(kind: .temporary, byteCount: UInt64(try PEXParserStorageSize.add(arrays, set)))
        }
        var netOrder: [String] = []
        var seenNets: Set<String> = []
        if scope != nil { netOrder.reserveCapacity(nodeOrder.count); seenNets.reserveCapacity(nodeOrder.count) }
        for n in nodeOrder {
            try scope?.check()
            if seenNets.insert(netName(n)).inserted { netOrder.append(netName(n)) }
        }
        if let scope {
            try scope.reserve(kind: .retained, byteCount: UInt64(
                try PEXParserStorageSize.array(ParasiticNet.self, count: netOrder.count)))
        }
        var nets: [ParasiticNet] = []
        if scope != nil { nets.reserveCapacity(netOrder.count) }
        for name in netOrder {
            var count = 0
            for n in nodeOrder { try scope?.check(); if netName(n) == name { count += 1 } }
            if let scope {
                try scope.reserve(kind: .retained, byteCount: UInt64(
                    try PEXParserStorageSize.array(ParasiticNode.self, count: count)))
            }
            var nodes: [ParasiticNode] = []
            if scope != nil { nodes.reserveCapacity(count) }
            for n in nodeOrder {
                try scope?.check()
                if netName(n) == name {
                    nodes.append(.init(name: NodeName(n), kind: .internal, instancePath: nil, coordinate: nil))
                }
            }
            nets.append(.init(name: NetName(name), nodes: nodes, totalGroundCapF: groundCap[name] ?? 0,
                totalCouplingCapF: couplingCap[name] ?? 0, totalResistanceOhm: resistance[name] ?? 0))
        }
        if let scope {
            try scope.reserve(kind: .retained, byteCount: UInt64(
                try PEXParserStorageSize.dictionary(String.self, String.self, count: 3)))
            if let topCell = context.topCell {
                try scope.reserve(kind: .temporary, byteCount: UInt64(
                    try PEXParserStorageSize.add(MemoryLayout<String>.stride, topCell.utf8.count)))
                try scope.check(UInt64(topCell.utf8.count))
            }
        }
        var metadata = [
            "sourceFormat": "magic-spice",
            "sourceFile": sourceFileName,
        ]
        if let topCell = context.topCell,
           !topCell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata["topCell"] = topCell
        }
        return ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: context.cornerID,
            units: .canonical,
            nets: nets,
            elements: elements,
            metadata: metadata
        )
    }

    private func shouldIncludeCapacitance(_ value: Double, options: PEXRunOptions) -> Bool {
        guard options.extractMode != .rOnly else { return false }
        if let minCapacitanceF = options.minCapacitanceF, value < minCapacitanceF {
            return false
        }
        return true
    }

    private func shouldIncludeResistance(_ value: Double, options: PEXRunOptions) -> Bool {
        guard options.extractMode != .cOnly else { return false }
        if let minResistanceOhm = options.minResistanceOhm, value < minResistanceOhm {
            return false
        }
        return true
    }

    private func shouldIncludeInductance(options: PEXRunOptions) -> Bool {
        options.extractMode == .rc
    }

    /// Parses a SPICE-style number with an optional engineering suffix into a
    /// canonical SI value. Returns nil for an unparseable mantissa or an
    /// unrecognized suffix (the caller fails loudly rather than mis-scaling).
    static func parseSPICEValue(_ token: String) -> Double? {
        let s = token.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        var end = s.startIndex
        var seenDigit = false
        var i = s.startIndex
        loop: while i < s.endIndex {
            let c = s[i]
            if c.isNumber {
                seenDigit = true
                i = s.index(after: i)
            } else if c == "." || c == "+" || c == "-" {
                i = s.index(after: i)
            } else if (c == "e" || c == "E") && seenDigit {
                var j = s.index(after: i)
                if j < s.endIndex, s[j] == "+" || s[j] == "-" { j = s.index(after: j) }
                guard j < s.endIndex, s[j].isNumber else { break loop }
                i = j
                while i < s.endIndex, s[i].isNumber { i = s.index(after: i) }
            } else {
                break loop
            }
            end = i
        }
        guard end > s.startIndex else { return nil }
        guard let mantissa = Double(String(s[s.startIndex..<end])) else { return nil }

        let suffix = String(s[end...]).lowercased()
        if suffix.isEmpty { return mantissa }
        let multiplier: Double
        switch suffix {
        case "meg": multiplier = 1e6
        case "t": multiplier = 1e12
        case "g": multiplier = 1e9
        case "k": multiplier = 1e3
        case "m": multiplier = 1e-3
        case "u": multiplier = 1e-6
        case "n": multiplier = 1e-9
        case "p": multiplier = 1e-12
        case "f": multiplier = 1e-15
        case "tf": multiplier = 1e12
        case "gf": multiplier = 1e9
        case "mf": multiplier = 1e-3
        case "uf": multiplier = 1e-6
        case "nf": multiplier = 1e-9
        case "pf": multiplier = 1e-12
        case "ff": multiplier = 1e-15
        default: return nil
        }
        return mantissa * multiplier
    }

    static func parseSPICEValue(_ token: String, scope: PEXParserResourceScope) throws -> Double? {
        try scope.reserve(kind: .temporary, byteCount: UInt64(
            try PEXParserStorageSize.add(MemoryLayout<String>.stride, token.utf8.count)))
        try scope.check(UInt64(token.utf8.count))
        let s = token.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        var end = s.startIndex
        var seenDigit = false
        var i = s.startIndex
        loop: while i < s.endIndex {
            try scope.check()
            let c = s[i]
            if c.isNumber {
                seenDigit = true
                i = s.index(after: i)
            } else if c == "." || c == "+" || c == "-" {
                i = s.index(after: i)
            } else if (c == "e" || c == "E") && seenDigit {
                var j = s.index(after: i)
                if j < s.endIndex, s[j] == "+" || s[j] == "-" { j = s.index(after: j) }
                guard j < s.endIndex, s[j].isNumber else { break loop }
                i = j
                while i < s.endIndex, s[i].isNumber { try scope.check(); i = s.index(after: i) }
            } else {
                break loop
            }
            end = i
        }
        guard end > s.startIndex else { return nil }
        let mantissaView = s[s.startIndex..<end]
        try scope.reserve(kind: .temporary, byteCount: UInt64(
            try PEXParserStorageSize.add(MemoryLayout<String>.stride, mantissaView.utf8.count)))
        try scope.check(UInt64(mantissaView.utf8.count))
        guard let mantissa = Double(String(mantissaView)) else { return nil }
        let suffixView = s[end...]
        try scope.reserve(kind: .temporary, byteCount: UInt64(
            try PEXParserStorageSize.add(MemoryLayout<String>.stride, suffixView.utf8.count)))
        let suffix = try PEXParserTextSizing.lowercased(String(suffixView), kind: .temporary, scope: scope)
        if suffix.isEmpty { return mantissa }
        let multiplier: Double
        switch suffix {
        case "meg": multiplier = 1e6
        case "t": multiplier = 1e12
        case "g": multiplier = 1e9
        case "k": multiplier = 1e3
        case "m": multiplier = 1e-3
        case "u": multiplier = 1e-6
        case "n": multiplier = 1e-9
        case "p": multiplier = 1e-12
        case "f": multiplier = 1e-15
        case "tf": multiplier = 1e12
        case "gf": multiplier = 1e9
        case "mf": multiplier = 1e-3
        case "uf": multiplier = 1e-6
        case "nf": multiplier = 1e-9
        case "pf": multiplier = 1e-12
        case "ff": multiplier = 1e-15
        default: return nil
        }
        return mantissa * multiplier
    }
}

private enum MagicSPICEElementKind {
    case capacitor
    case resistor
    case inductor

    var rawName: String {
        switch self {
        case .capacitor:
            return "capacitor"
        case .resistor:
            return "resistor"
        case .inductor:
            return "inductor"
        }
    }

    init?(rawPrefix: Character) {
        switch rawPrefix.lowercased() {
        case "c":
            self = .capacitor
        case "r":
            self = .resistor
        case "l":
            self = .inductor
        default:
            return nil
        }
    }
}

private struct MagicSPICEElementLine {
    var kind: MagicSPICEElementKind
    var nodeA: String
    var nodeB: String
    var value: Double
}

private struct MagicSPICEElementTokens {
    var nodeA: String
    var nodeB: String
    var valueToken: String

    init?(tokens: [String]) {
        var iterator = tokens.makeIterator()
        guard iterator.next() != nil,
              let nodeA = iterator.next(),
              let nodeB = iterator.next(),
              let valueToken = iterator.next() else {
            return nil
        }
        self.nodeA = nodeA
        self.nodeB = nodeB
        self.valueToken = valueToken
    }
}

private struct MagicSPICERecords {
    var grounds: [MagicGroundCapRecord] = []
    var couplings: [MagicPairRecord] = []
    var resistors: [MagicPairRecord] = []
    var inductors: [MagicPairRecord] = []
    var connectivity = MagicNodeConnectivity()

    mutating func prepare(lineCount: Int, scope: PEXParserResourceScope) throws {
        let groundsBytes = try PEXParserStorageSize.array(MagicGroundCapRecord.self, count: lineCount)
        let pairsBytes = try PEXParserStorageSize.array(MagicPairRecord.self, count: lineCount)
        try scope.reserve(kind: .temporary, byteCount: UInt64(
            try PEXParserStorageSize.add(groundsBytes, PEXParserStorageSize.multiply(pairsBytes, 3))))
        grounds.reserveCapacity(lineCount); couplings.reserveCapacity(lineCount)
        resistors.reserveCapacity(lineCount); inductors.reserveCapacity(lineCount)
        try connectivity.prepare(count: PEXParserStorageSize.multiply(lineCount, 2), scope: scope)
    }
}

private struct MagicGroundCapRecord {
    var signal: String
    var value: Double
}

private struct MagicPairRecord {
    var a: String
    var b: String
    var value: Double
}

private struct MagicNodeConnectivity {
    private(set) var nodeOrder: [String] = []
    private var seenNodes: Set<String> = []
    private var parent: [String: String] = [:]

    mutating func prepare(count: Int, scope: PEXParserResourceScope) throws {
        let set = try PEXParserStorageSize.add(MemoryLayout<Set<String>>.stride,
            PEXParserStorageSize.multiply(count, MemoryLayout<String>.stride))
        let bytes = try PEXParserStorageSize.add(set, PEXParserStorageSize.add(
            PEXParserStorageSize.array(String.self, count: count),
            PEXParserStorageSize.dictionary(String.self, String.self, count: count)))
        try scope.reserve(kind: .temporary, byteCount: UInt64(bytes))
        nodeOrder.reserveCapacity(count); seenNodes.reserveCapacity(count); parent.reserveCapacity(count)
    }

    mutating func see(_ node: String, scope: PEXParserResourceScope?) throws {
        try scope?.check()
        if parent[node] == nil {
            parent[node] = node
        }
        if seenNodes.insert(node).inserted {
            nodeOrder.append(node)
        }
    }

    mutating func union(_ lhs: String, _ rhs: String, scope: PEXParserResourceScope?) throws {
        let lhsRoot = try find(lhs, scope: scope)
        let rhsRoot = try find(rhs, scope: scope)
        if lhsRoot != rhsRoot {
            parent[rhsRoot] = lhsRoot
        }
    }

    func netNameMap(scope: PEXParserResourceScope?) throws -> [String: String] {
        if let scope {
            // The private copy may detach parent during path compression. Both
            // parent buffers coexist with component membership and result maps.
            let maps = try PEXParserStorageSize.multiply(
                PEXParserStorageSize.dictionary(String.self, String.self, count: nodeOrder.count), 2)
            let groups = try PEXParserStorageSize.dictionary(String.self, [String].self, count: nodeOrder.count)
            let members = try PEXParserStorageSize.array(String.self, count: nodeOrder.count)
            try scope.reserve(kind: .temporary, byteCount: UInt64(
                try PEXParserStorageSize.add(maps, PEXParserStorageSize.add(groups, members))))
        }
        var copy = self
        return try copy.makeNetNameMap(scope: scope)
    }

    private mutating func makeNetNameMap(scope: PEXParserResourceScope?) throws -> [String: String] {
        // A root-to-minimum map replaces transient per-component arrays; it
        // preserves the original lexicographic net-name choice exactly.
        var componentMinimum: [String: String] = [:]
        if scope != nil { componentMinimum.reserveCapacity(nodeOrder.count) }
        for node in nodeOrder {
            try scope?.check()
            let root = try find(node, scope: scope)
            if let previous = componentMinimum[root] {
                if node < previous { componentMinimum[root] = node }
            } else { componentMinimum[root] = node }
        }

        var netNameOf: [String: String] = [:]
        if scope != nil { netNameOf.reserveCapacity(nodeOrder.count) }
        for node in nodeOrder {
            try scope?.check()
            netNameOf[node] = componentMinimum[try find(node, scope: scope)]
        }
        return netNameOf
    }

    private mutating func find(_ node: String, scope: PEXParserResourceScope?) throws -> String {
        try scope?.check()
        if parent[node] == nil {
            parent[node] = node
        }
        var root = node
        while let next = parent[root], next != root {
            try scope?.check()
            root = next
        }
        var cursor = node
        while let next = parent[cursor], next != root {
            try scope?.check()
            parent[cursor] = root
            cursor = next
        }
        return root
    }
}
