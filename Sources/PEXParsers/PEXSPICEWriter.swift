import Foundation
import PEXCore

/// Writes a deterministic, standalone SPICE subcircuit containing every
/// nonnegative parasitic element in canonical ParasiticIR.
///
/// The writer deliberately does not rewrite the source netlist.  It preserves
/// the extracted topology in a reusable fragment and emits a node map when a
/// net-scoped internal node must be made globally unique for SPICE.
public struct PEXSPICEWriter: Sendable {
    private let options: PEXSPICEWriterOptions
    private let scope: PEXParserResourceScope?

    public init(options: PEXSPICEWriterOptions = PEXSPICEWriterOptions()) {
        self.options = options; self.scope = nil
    }

    private init(options: PEXSPICEWriterOptions, scope: PEXParserResourceScope) {
        self.options = options; self.scope = scope
    }
    public func write(_ ir: ParasiticIR) throws -> String { try writeValue(ir) }
    public func write(_ ir: ParasiticIR, control: any PEXParserResourceControlling)
        throws -> (value: String, retention: PEXParserRetention) {
        let scope = try PEXParserResourceScope(control: control)
        return (try write(ir, scope: scope), scope.retention)
    }
    func write(_ ir: ParasiticIR, scope: PEXParserResourceScope,
               outputKind: PEXParserStorageKind = .retained) throws -> String {
        try Self(options: options, scope: scope).writeValue(ir, outputKind: outputKind)
    }
    private func writeValue(_ ir: ParasiticIR, outputKind: PEXParserStorageKind = .retained) throws -> String {
        try scope?.check()
        let referenceName = ir.metadata["referenceNodeName"] ?? "0"
        try validateNodeToken(referenceName, original: referenceName)
        let referenceToken = referenceName == "0" ? "0" : try PEXSPICEConstruction.text("PEX_REFERENCE_", try identityHex(referenceName), scope: scope)
        let nodeMap = try makeNodeMap(for: ir, referenceToken: referenceToken)
        let elementIDs = try makeElementIDs(for: ir)
        let subcircuit = try makeSubcircuitName(for: ir)
        var portCount = 0
        for net in ir.nets { for node in net.nodes { try scope?.check(); if node.kind == .pin { portCount = try PEXParserStorageSize.add(portCount, 1) } } }
        try PEXSPICEConstruction.array(String.self, count: try PEXParserStorageSize.add(portCount, 1), scope: scope)
        try PEXSPICEConstruction.set(String.self, count: portCount, scope: scope)
        var ports: [String] = [], seenPorts: Set<String> = []
        ports.reserveCapacity(try PEXParserStorageSize.add(portCount, 1)); seenPorts.reserveCapacity(portCount)
        for net in ir.nets {
            for node in net.nodes {
                try scope?.check()
                guard node.kind == .pin, let token = nodeMap[NodeRef(netName: net.name, nodeName: node.name)], token != "0" else { continue }
                if seenPorts.insert(token).inserted { ports.append(token) }
            }
        }
        var hasGroundCapacitor = false
        if referenceToken != "0" {
            for element in ir.elements {
                try scope?.check()
                if element.kind == .capacitor && element.nodeB == nil { hasGroundCapacitor = true; break }
            }
        }
        if referenceToken != "0" && hasGroundCapacitor {
            ports.append(referenceToken)
        }
        let nodeCount = nodeMap.values.count
        try PEXSPICEConstruction.dictionary(String.self, PEXSPICEIdentity.Node.self, count: nodeCount, scope: scope)
        var identityNodes: [String: PEXSPICEIdentity.Node] = [:]
        identityNodes.reserveCapacity(nodeCount)
        for net in ir.nets {
            for node in net.nodes {
                try scope?.check()
                let ref = NodeRef(netName: net.name, nodeName: node.name)
                guard let token = nodeMap[ref] else { throw try PEXSPICEConstruction.failure(bytes: node.name.value.utf8.count, scope: scope) { PEXSPICEWriterError.invalidNodeName(node.name.value) } }
                identityNodes[token] = PEXSPICEIdentity.Node(ref: ref, kind: node.kind)
            }
        }
        try PEXSPICEConstruction.dictionary(String.self, ElementKind.self, count: ir.elements.count, scope: scope)
        var kinds: [String: ElementKind] = [:]
        kinds.reserveCapacity(ir.elements.count)
        for element in ir.elements {
            try scope?.check()
            guard let id = elementIDs[element.id] else { throw try PEXSPICEConstruction.failure(bytes: element.id.utf8.count, scope: scope) { PEXSPICEWriterError.invalidElementIdentifier(element.id) } }
            let prefix = element.kind == .resistor ? "R" : element.kind == .inductor ? "L" : "C"
            kinds[try PEXSPICEConstruction.text(prefix, "PEX_", id, scope: scope)] = element.kind
        }
        let identity = PEXSPICEIdentity(nodes: identityNodes, elementKinds: kinds, referenceName: referenceName, referenceToken: referenceToken)
        let maximumLines = try PEXParserStorageSize.add(7, PEXParserStorageSize.add(ir.elements.count, options.includeNodeMapComments ? nodeCount : 0))
        try PEXSPICEConstruction.array(String.self, count: maximumLines, scope: scope)
        var lines: [String] = []
        lines.reserveCapacity(maximumLines)
        lines.append(try PEXSPICEConstruction.text("* PEX backannotation generated from ParasiticIR ", ir.version, scope: scope))
        lines.append(try identityComment(identity))
        lines.append(try PEXSPICEConstruction.text("* Corner: ", ir.cornerID.value, scope: scope))
        lines.append("* Units: resistance=ohm capacitance=F inductance=H")
        if options.includeNodeMapComments {
            for entry in try nodeMap.entries(scope: scope) {
                try scope?.check()
                guard entry.key.nodeName.value != entry.value else { continue }
                lines.append(try PEXSPICEConstruction.text("* PEX_NODE_MAP ", try commentToken(entry.key.netName.value), " ", try commentToken(entry.key.nodeName.value), " -> ", entry.value, scope: scope))
            }
        }
        let portText = try PEXSPICEConstruction.join(ports, separator: " ", scope: scope)
        let portSuffix = portText.isEmpty ? "" : try PEXSPICEConstruction.text(" ", portText, scope: scope)
        lines.append(try PEXSPICEConstruction.text(".subckt ", subcircuit, portSuffix, scope: scope))

        for index in try PEXSPICEConstruction.ordered(count: ir.elements.count, scope: scope, less: { ir.elements[$0].id < ir.elements[$1].id }) {
            try scope?.check()
            let element = ir.elements[index]
            guard element.value.isFinite else { throw try PEXSPICEConstruction.failure(bytes: element.id.utf8.count, scope: scope) { PEXSPICEWriterError.nonFiniteValue(element.id) } }
            guard element.value >= 0 else { throw try PEXSPICEConstruction.failure(bytes: element.id.utf8.count, scope: scope) { PEXSPICEWriterError.negativeValue(element.id) } }
            guard let elementID = elementIDs[element.id] else {
                throw try PEXSPICEConstruction.failure(bytes: element.id.utf8.count, scope: scope) { PEXSPICEWriterError.invalidElementIdentifier(element.id) }
            }
            let nodeA = try nodeToken(for: element.nodeA, nodeMap: nodeMap)
            let value: Double
            switch element.kind {
            case .resistor:
                guard let nodeB = element.nodeB else { throw try PEXSPICEConstruction.failure(bytes: element.id.utf8.count, scope: scope) { PEXSPICEWriterError.missingEndpoint(element.id) } }
                value = element.value * resistanceScale(ir.units.resistance)
                lines.append(try PEXSPICEConstruction.text("RPEX_", elementID, " ", nodeA, " ", try nodeToken(for: nodeB, nodeMap: nodeMap), " ", try checkedFormat(value, id: element.id), scope: scope))
            case .capacitor:
                value = element.value * capacitanceScale(ir.units.capacitance)
                let nodeB: String
                if let ref = element.nodeB {
                    nodeB = try nodeToken(for: ref, nodeMap: nodeMap)
                } else {
                    nodeB = referenceToken
                }
                lines.append(try PEXSPICEConstruction.text("CPEX_", elementID, " ", nodeA, " ", nodeB, " ", try checkedFormat(value, id: element.id), scope: scope))
            case .coupling:
                guard let nodeB = element.nodeB else { throw try PEXSPICEConstruction.failure(bytes: element.id.utf8.count, scope: scope) { PEXSPICEWriterError.missingEndpoint(element.id) } }
                value = element.value * capacitanceScale(ir.units.capacitance)
                lines.append(try PEXSPICEConstruction.text("CPEX_", elementID, " ", nodeA, " ", try nodeToken(for: nodeB, nodeMap: nodeMap), " ", try checkedFormat(value, id: element.id), scope: scope))
            case .inductor:
                guard let nodeB = element.nodeB else { throw try PEXSPICEConstruction.failure(bytes: element.id.utf8.count, scope: scope) { PEXSPICEWriterError.missingEndpoint(element.id) } }
                value = element.value
                lines.append(try PEXSPICEConstruction.text("LPEX_", elementID, " ", nodeA, " ", try nodeToken(for: nodeB, nodeMap: nodeMap), " ", try checkedFormat(value, id: element.id), scope: scope))
            }
        }

        lines.append(try PEXSPICEConstruction.text(".ends ", subcircuit, scope: scope))
        return try PEXSPICEConstruction.join(lines, separator: "\n", trailing: "\n", kind: outputKind, scope: scope)
    }

    public func write(_ ir: ParasiticIR, to url: URL) throws {
        do {
            try Data(write(ir).utf8).write(to: url, options: .atomic)
        } catch let error as PEXSPICEWriterError {
            throw error
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to write SPICE backannotation to \(url.path(percentEncoded: false))",
                underlying: error
            )
        }
    }

    private func makeSubcircuitName(for ir: ParasiticIR) throws -> String {
        let raw = try options.subcircuitName ?? PEXSPICEConstruction.text("PEX_", ir.metadata["topCell"] ?? "TOP", "_", ir.cornerID.value, scope: scope)
        let value = try PEXSPICEConstruction.sanitize(raw, scope: scope)
        guard !value.isEmpty else { throw try PEXSPICEConstruction.failure(bytes: raw.utf8.count, scope: scope) { PEXSPICEWriterError.invalidElementIdentifier(raw) } }
        return value
    }

    private func makeElementIDs(for ir: ParasiticIR) throws -> [String: String] {
        try PEXSPICEConstruction.set(String.self, count: ir.elements.count, scope: scope)
        try PEXSPICEConstruction.dictionary(String.self, String.self, count: ir.elements.count, scope: scope)
        var used: Set<String> = []
        var result: [String: String] = [:]
        used.reserveCapacity(ir.elements.count); result.reserveCapacity(ir.elements.count)
        for index in try PEXSPICEConstruction.ordered(count: ir.elements.count, scope: scope, less: { ir.elements[$0].id < ir.elements[$1].id }) {
            try scope?.check()
            let element = ir.elements[index]
            let base = try PEXSPICEConstruction.sanitize(element.id, scope: scope)
            guard !base.isEmpty else { throw try PEXSPICEConstruction.failure(bytes: element.id.utf8.count, scope: scope) { PEXSPICEWriterError.invalidElementIdentifier(element.id) } }
            var candidate = base
            var suffix = 2
            while !used.insert(try PEXSPICEConstruction.lower(candidate, scope: scope)).inserted {
                try scope?.check()
                candidate = try PEXSPICEConstruction.text(base, "_", try PEXSPICEConstruction.integer(suffix, scope: scope), scope: scope)
                let next = suffix.addingReportingOverflow(1)
                guard !next.overflow else { throw PEXParserResourceError.capacityOverflow }
                suffix = next.partialValue
            }
            guard result[element.id] == nil else { throw try PEXSPICEConstruction.failure(bytes: element.id.utf8.count, scope: scope) { PEXSPICEWriterError.invalidElementIdentifier(element.id) } }
            result[element.id] = candidate
        }
        return result
    }

    private func makeNodeMap(for ir: ParasiticIR, referenceToken: String) throws -> NodeMap {
        var count = 0
        for net in ir.nets { try scope?.check(); count = try PEXParserStorageSize.add(count, net.nodes.count) }
        try PEXSPICEConstruction.array(NodeRef.self, count: count, scope: scope)
        try PEXSPICEConstruction.set(NetName.self, count: ir.nets.count, scope: scope)
        try PEXSPICEConstruction.set(NodeRef.self, count: count, scope: scope)
        var refs: [NodeRef] = [], nets: Set<NetName> = [], seen: Set<NodeRef> = []
        refs.reserveCapacity(count); nets.reserveCapacity(ir.nets.count); seen.reserveCapacity(count)
        for net in ir.nets {
            try scope?.check()
            guard nets.insert(net.name).inserted else { throw try PEXSPICEConstruction.failure(bytes: 0, scope: scope) { PEXSPICEWriterError.nodeIdentityCollision("Duplicate canonical net or node") } }
            for node in net.nodes {
                try scope?.check()
                let ref = NodeRef(netName: net.name, nodeName: node.name)
                guard seen.insert(ref).inserted else { throw try PEXSPICEConstruction.failure(bytes: 0, scope: scope) { PEXSPICEWriterError.nodeIdentityCollision("Duplicate canonical net or node") } }
                refs.append(ref)
            }
        }
        try PEXSPICEConstruction.dictionary(String.self, Int.self, count: count, scope: scope)
        var counts: [String: Int] = [:]; counts.reserveCapacity(count)
        for ref in refs { try scope?.check(); counts[try PEXSPICEConstruction.lower(ref.nodeName.value, scope: scope), default: 0] += 1 }
        try PEXSPICEConstruction.dictionary(NodeRef.self, String.self, count: count, scope: scope)
        try PEXSPICEConstruction.set(String.self, count: try PEXParserStorageSize.add(count, 2), scope: scope)
        var map: [NodeRef: String] = [:], owners: Set<String> = []
        map.reserveCapacity(count); owners.reserveCapacity(try PEXParserStorageSize.add(count, 2))
        owners.insert(try PEXSPICEConstruction.lower(referenceToken, scope: scope)); owners.insert("0")
        for ref in refs {
            try scope?.check()
            try validateNodeToken(ref.nodeName.value, original: ref.nodeName.value)
            guard !ref.netName.value.isEmpty else { throw try PEXSPICEConstruction.failure(bytes: ref.netName.value.utf8.count, scope: scope) { PEXSPICEWriterError.invalidNodeName(ref.netName.value) } }
            let raw = ref.nodeName.value
            let lower = try PEXSPICEConstruction.lower(raw, scope: scope)
            let mustEncode = counts[lower] != 1 || lower == "0" || lower == "gnd"
                || lower == "gnd!" || lower == "vsubs" || lower.hasPrefix("pex_")
            let token = mustEncode ? try identityToken(ref) : raw
            guard owners.insert(try PEXSPICEConstruction.lower(token, scope: scope)).inserted else {
                throw try PEXSPICEConstruction.failure(bytes: token.utf8.count, scope: scope) { PEXSPICEWriterError.nodeIdentityCollision(token) }
            }
            map[ref] = token
        }
        return NodeMap(values: map)
    }

    private func nodeToken(for ref: NodeRef, nodeMap: NodeMap) throws -> String {
        guard let token = nodeMap[ref] else {
            let bytes = try PEXParserStorageSize.add(1, PEXParserStorageSize.add(ref.netName.value.utf8.count, ref.nodeName.value.utf8.count))
            throw try PEXSPICEConstruction.failure(bytes: bytes, scope: scope) {
                PEXSPICEWriterError.invalidNodeName("\(ref.netName.value):\(ref.nodeName.value)")
            }
        }
        return token
    }

    private func validateNodeToken(_ value: String, original: String) throws {
        guard !value.isEmpty else { throw try PEXSPICEConstruction.failure(bytes: original.utf8.count, scope: scope) { PEXSPICEWriterError.invalidNodeName(original) } }
        for character in value {
            try scope?.check()
            if character.isWhitespace || character.isNewline || character == ";" || character == "\"" || character == "(" || character == ")" {
                throw try PEXSPICEConstruction.failure(bytes: original.utf8.count, scope: scope) { PEXSPICEWriterError.invalidNodeName(original) }
            }
        }
    }

    private func commentToken(_ value: String) throws -> String {
        var bytes = 0
        for scalar in value.unicodeScalars {
            try scope?.check()
            bytes = try PEXParserStorageSize.add(bytes, scalar.value == 10 || scalar.value == 13 ? 1 : scalar.utf8.count)
        }
        try PEXSPICEConstruction.string(bytes: bytes, scope: scope)
        var result = String(); result.reserveCapacity(bytes)
        for scalar in value.unicodeScalars {
            try scope?.check()
            if scalar.value == 10 || scalar.value == 13 { result.append("_") }
            else { result.unicodeScalars.append(scalar) }
        }
        return result
    }
    private func identityHex(_ value: String) throws -> String {
        if let scope { return try PEXSPICEIdentity.hex(value, scope: scope) }
        return PEXSPICEIdentity.hex(value)
    }
    private func identityToken(_ ref: NodeRef) throws -> String {
        if let scope { return try PEXSPICEIdentity.encodedToken(ref, scope: scope) }
        return PEXSPICEIdentity.encodedToken(ref)
    }
    private func identityComment(_ identity: PEXSPICEIdentity) throws -> String {
        if let scope { return try identity.comment(scope: scope) }
        return try identity.comment()
    }

    private func resistanceScale(_ unit: ParasiticUnits.ResistanceUnit) -> Double {
        switch unit {
        case .ohm: return 1
        case .kiloOhm: return 1_000
        }
    }

    private func capacitanceScale(_ unit: ParasiticUnits.CapacitanceUnit) -> Double {
        switch unit {
        case .farad: return 1
        case .picoFarad: return 1e-12
        case .femtoFarad: return 1e-15
        }
    }

    private func checkedFormat(_ value: Double, id: String) throws -> String {
        guard value.isFinite else { throw try PEXSPICEConstruction.failure(bytes: id.utf8.count, scope: scope) { PEXSPICEWriterError.nonFiniteValue(id) } }
        // Binary64 shortest round-trip text: 17 digits, sign, point, e/sign, three exponent digits.
        let maximumBytes = 24
        try PEXSPICEConstruction.string(bytes: maximumBytes, scope: scope)
        try scope?.check()
        let text = String(value)
        guard text.utf8.count <= maximumBytes else { throw PEXParserResourceError.capacityOverflow }
        return text
    }
}

private struct NodeMap: Sendable {
    let values: [NodeRef: String]

    subscript(_ ref: NodeRef) -> String? { values[ref] }

    func entries(scope: PEXParserResourceScope?) throws -> [(key: NodeRef, value: String)] {
        try PEXSPICEConstruction.array((key: NodeRef, value: String).self, count: values.count, scope: scope)
        var entries: [(key: NodeRef, value: String)] = []; entries.reserveCapacity(values.count)
        for entry in values { try scope?.check(); entries.append(entry) }
        let order = try PEXSPICEConstruction.ordered(count: entries.count, scope: scope) { a, b in
            if entries[a].key.netName.value != entries[b].key.netName.value { return entries[a].key.netName.value < entries[b].key.netName.value }
            return entries[a].key.nodeName.value < entries[b].key.nodeName.value
        }
        try PEXSPICEConstruction.array((key: NodeRef, value: String).self, count: values.count, scope: scope)
        var result: [(key: NodeRef, value: String)] = []; result.reserveCapacity(values.count)
        for index in order { try scope?.check(); result.append(entries[index]) }
        return result
    }
}

/// Construction helpers shared only by the SPICE writer and composer. Each
/// explicit container and text buffer is admitted before its first mutation.
enum PEXSPICEConstruction {
    static func failure<Failure: Error>(bytes: Int, scope: PEXParserResourceScope?,
                                       _ make: () -> Failure) throws -> any Error {
        if let scope { return try scope.sourceFailure(diagnosticBytes: bytes, make) }
        return make()
    }
    static func array<T>(_ type: T.Type, count: Int, scope: PEXParserResourceScope?) throws {
        if let scope { try scope.reserve(kind: .temporary, byteCount: UInt64(try PEXParserStorageSize.array(type, count: count))) }
    }
    static func dictionary<K: Hashable, V>(_ key: K.Type, _ value: V.Type, count: Int, scope: PEXParserResourceScope?) throws {
        if let scope { try scope.reserve(kind: .temporary, byteCount: UInt64(try PEXParserStorageSize.dictionary(key, value, count: count))) }
    }
    static func set<T: Hashable>(_ type: T.Type, count: Int, scope: PEXParserResourceScope?) throws {
        if let scope {
            let bytes = try PEXParserStorageSize.add(MemoryLayout<Set<T>>.stride, PEXParserStorageSize.multiply(count, MemoryLayout<T>.stride))
            try scope.reserve(kind: .temporary, byteCount: UInt64(bytes))
        }
    }
    static func string(bytes: Int, kind: PEXParserStorageKind = .temporary, scope: PEXParserResourceScope?) throws {
        if let scope { try scope.reserve(kind: kind, byteCount: UInt64(try PEXParserStorageSize.add(MemoryLayout<String>.stride, bytes))) }
    }
    static func text(_ a: String, _ b: String = "", _ c: String = "", _ d: String = "",
                     _ e: String = "", _ f: String = "", _ g: String = "", _ h: String = "",
                     scope: PEXParserResourceScope?) throws -> String {
        var count = 0
        count = try PEXParserStorageSize.add(count, a.utf8.count)
        count = try PEXParserStorageSize.add(count, b.utf8.count)
        count = try PEXParserStorageSize.add(count, c.utf8.count)
        count = try PEXParserStorageSize.add(count, d.utf8.count)
        count = try PEXParserStorageSize.add(count, e.utf8.count)
        count = try PEXParserStorageSize.add(count, f.utf8.count)
        count = try PEXParserStorageSize.add(count, g.utf8.count)
        count = try PEXParserStorageSize.add(count, h.utf8.count)
        try string(bytes: count, scope: scope)
        var result = String(); result.reserveCapacity(count)
        try append(a, to: &result, scope: scope); try append(b, to: &result, scope: scope)
        try append(c, to: &result, scope: scope); try append(d, to: &result, scope: scope)
        try append(e, to: &result, scope: scope); try append(f, to: &result, scope: scope)
        try append(g, to: &result, scope: scope); try append(h, to: &result, scope: scope)
        return result
    }
    private static func append(_ value: String, to result: inout String, scope: PEXParserResourceScope?) throws {
        // Append in bounded source units rather than one opaque whole-deck copy.
        for character in value { try scope?.check(); result.append(character) }
    }
    static func join(_ values: [String], separator: String, trailing: String = "",
                     kind: PEXParserStorageKind = .temporary, scope: PEXParserResourceScope?) throws -> String {
        var bytes = trailing.utf8.count
        if !values.isEmpty { bytes = try PEXParserStorageSize.add(bytes, PEXParserStorageSize.multiply(values.count - 1, separator.utf8.count)) }
        for value in values { try scope?.check(); bytes = try PEXParserStorageSize.add(bytes, value.utf8.count) }
        try string(bytes: bytes, kind: kind, scope: scope)
        var result = String(); result.reserveCapacity(bytes)
        for index in values.indices {
            try scope?.check()
            if index > 0 { try append(separator, to: &result, scope: scope) }
            try append(values[index], to: &result, scope: scope)
        }
        try append(trailing, to: &result, scope: scope)
        try scope?.check(0)
        return result
    }
    static func lower(_ value: String, scope: PEXParserResourceScope?) throws -> String {
        if let scope { return try PEXParserTextSizing.lowercased(value, kind: .temporary, scope: scope) }
        return value.lowercased()
    }
    static func upper(_ value: String, scope: PEXParserResourceScope?) throws -> String {
        if let scope { return try PEXParserTextSizing.uppercased(value, kind: .temporary, scope: scope) }
        return value.uppercased()
    }
    static func integer(_ value: Int, scope: PEXParserResourceScope?) throws -> String {
        // Decimal Int64 needs at most 19 digits and one minus sign.
        try string(bytes: 20, scope: scope)
        let result = String(value)
        guard result.utf8.count <= 20 else { throw PEXParserResourceError.capacityOverflow }
        return result
    }
    static func sanitize(_ value: String, scope: PEXParserResourceScope?) throws -> String {
        // Trim the mapped boundary underscores before construction, so no
        // intermediate Character array or second String buffer is needed.
        var first: String.Index?, last: String.Index?, bytes = 0
        var index = value.startIndex
        while index < value.endIndex {
            try scope?.check()
            let character = value[index]
            if character.isLetter || character.isNumber {
                if first == nil { first = index }
                last = value.index(after: index)
            }
            index = value.index(after: index)
        }
        guard let first, let last else { return "" }
        index = first
        while index < last {
            try scope?.check()
            let character = value[index]
            if character.isLetter || character.isNumber || character == "_" {
                for scalar in character.unicodeScalars { try scope?.check(); bytes = try PEXParserStorageSize.add(bytes, scalar.utf8.count) }
            } else { bytes = try PEXParserStorageSize.add(bytes, 1) }
            index = value.index(after: index)
        }
        try string(bytes: bytes, scope: scope)
        var result = String(); result.reserveCapacity(bytes)
        index = first
        while index < last {
            try scope?.check()
            let character = value[index]
            result.append(character.isLetter || character.isNumber || character == "_" ? character : "_")
            index = value.index(after: index)
        }
        return result
    }
    static func copy(_ value: Substring, scope: PEXParserResourceScope?) throws -> String {
        try string(bytes: value.utf8.count, scope: scope)
        try scope?.check(UInt64(value.utf8.count))
        let result = String(value)
        try scope?.check(0)
        return result
    }
    static func lines(_ value: String, scope: PEXParserResourceScope?) throws -> [String] {
        var count = 1
        for character in value { try scope?.check(); if character == "\n" { count = try PEXParserStorageSize.add(count, 1) } }
        try array(String.self, count: count, scope: scope)
        var result: [String] = []; result.reserveCapacity(count)
        var start = value.startIndex, index = start
        while index < value.endIndex {
            try scope?.check()
            if value[index] == "\n" {
                result.append(try copy(value[start..<index], scope: scope))
                start = value.index(after: index)
            }
            index = value.index(after: index)
        }
        result.append(try copy(value[start..<value.endIndex], scope: scope))
        return result
    }
    static func words(_ value: String, scope: PEXParserResourceScope?) throws -> [String] {
        var count = 0, inWord = false
        for character in value {
            try scope?.check()
            if character.isWhitespace { inWord = false }
            else if !inWord { count = try PEXParserStorageSize.add(count, 1); inWord = true }
        }
        try array(String.self, count: count, scope: scope)
        var result: [String] = []; result.reserveCapacity(count)
        var start: String.Index?, index = value.startIndex
        while index < value.endIndex {
            try scope?.check()
            if value[index].isWhitespace {
                if let begin = start { result.append(try copy(value[begin..<index], scope: scope)); start = nil }
            } else if start == nil { start = index }
            index = value.index(after: index)
        }
        if let begin = start { result.append(try copy(value[begin..<value.endIndex], scope: scope)) }
        return result
    }
    static func ordered(count: Int, scope: PEXParserResourceScope?, less: (Int, Int) throws -> Bool) throws -> [Int] {
        try array(Int.self, count: count, scope: scope)
        try array(Int.self, count: count, scope: scope)
        var current: [Int] = [], next: [Int] = []
        current.reserveCapacity(count); next.reserveCapacity(count)
        for index in 0..<count { try scope?.check(); current.append(index); next.append(0) }
        var width = 1
        while width < count {
            var start = 0
            while start < count {
                let middle = start + min(width, count - start)
                let end = middle + min(width, count - middle)
                var left = start, right = middle, output = start
                while output < end {
                    try scope?.check()
                    let takeLeft: Bool
                    if left == middle { takeLeft = false }
                    else if right == end { takeLeft = true }
                    else { takeLeft = try !less(current[right], current[left]) }
                    if takeLeft { next[output] = current[left]; left += 1 }
                    else { next[output] = current[right]; right += 1 }
                    output += 1
                }
                start = end
            }
            swap(&current, &next)
            width = width > count / 2 ? count : width * 2
        }
        return current
    }
}
