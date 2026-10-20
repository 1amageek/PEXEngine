import PEXCore

/// The ordinary SPEF lowerer's finite logical capacity envelope.
/// Counts follow its distinct global maps, per-net maps and output inventories.
enum PEXParserLoweringStorage {
    static func admit(_ tree: SPEFParseTree, scope: PEXParserResourceScope) throws {
        var references = 0, elements = 0, connections = 0, coordinates = 0
        var names = 0, connectionNames = 0, portNames = 0, endpointNames = 0
        var capacitorNames = 0, netNames = 0, identifiers = 0, longest = 0
        func expanded(_ name: String) throws -> Int {
            try resolvedNameByteCount(name, nameMap: tree.nameMap, scope: scope)
        }
        for port in tree.ports {
            try scope.check()
            let bytes = try expanded(port.name)
            portNames = try PEXParserStorageSize.add(portNames, bytes)
            references = try PEXParserStorageSize.add(references, 1)
            names = try PEXParserStorageSize.add(names, bytes)
            longest = Swift.max(longest, bytes)
        }
        for block in tree.nets {
            try scope.check()
            let netBytes = try expanded(block.netName)
            netNames = try PEXParserStorageSize.add(netNames, netBytes)
            references = try PEXParserStorageSize.add(references, 1)
            names = try PEXParserStorageSize.add(names, netBytes)
            longest = Swift.max(longest, netBytes)
            for connection in block.connections {
                try scope.check()
                let bytes = try expanded(connection.name)
                connections = try PEXParserStorageSize.add(connections, 1)
                references = try PEXParserStorageSize.add(references, 1)
                names = try PEXParserStorageSize.add(names, bytes)
                connectionNames = try PEXParserStorageSize.add(connectionNames, bytes)
                longest = Swift.max(longest, bytes)
            }
            for coordinate in block.nodeCoordinates {
                try scope.check()
                let bytes = try expanded(coordinate.name)
                coordinates = try PEXParserStorageSize.add(coordinates, 1)
                references = try PEXParserStorageSize.add(references, 1)
                names = try PEXParserStorageSize.add(names, bytes)
                longest = Swift.max(longest, bytes)
            }
            func endpoint(_ name: String, capacitor: Bool) throws {
                try scope.check()
                let bytes = try expanded(name)
                references = try PEXParserStorageSize.add(references, 1)
                names = try PEXParserStorageSize.add(names, bytes)
                endpointNames = try PEXParserStorageSize.add(endpointNames, bytes)
                if capacitor { capacitorNames = try PEXParserStorageSize.add(capacitorNames, bytes) }
                longest = Swift.max(longest, bytes)
            }
            func element() throws {
                elements = try PEXParserStorageSize.add(elements, 1)
                // Net prefix, underscore/kind, and signed decimal Int identifier.
                identifiers = try PEXParserStorageSize.add(identifiers,
                    PEXParserStorageSize.add(netBytes, 2 + 20))
            }
            for value in block.capacitors {
                try element(); try endpoint(value.nodeA, capacitor: true)
                if let b = value.nodeB { try endpoint(b, capacitor: true) }
            }
            for value in block.resistors {
                try element(); try endpoint(value.nodeA, capacitor: false); try endpoint(value.nodeB, capacitor: false)
            }
            for value in block.inductors {
                try element(); try endpoint(value.nodeA, capacitor: false); try endpoint(value.nodeB, capacitor: false)
            }
        }
        let maxNets = try PEXParserStorageSize.add(tree.nets.count, references)
        let maxNodes = try PEXParserStorageSize.multiply(references, 2)
        var output = MemoryLayout<ParasiticIR>.stride
        output = try PEXParserStorageSize.add(output, PEXParserStorageSize.array(ParasiticNet.self, count: maxNets))
        output = try PEXParserStorageSize.add(output, PEXParserStorageSize.array(ParasiticNode.self, count: maxNodes))
        output = try PEXParserStorageSize.add(output, PEXParserStorageSize.array(ParasiticElement.self, count: elements))
        // Node spellings, independently resolved element endpoints, external
        // owner prefixes, instance paths, net names and generated identifiers.
        output = try PEXParserStorageSize.add(output, names)
        output = try PEXParserStorageSize.add(output, endpointNames)
        output = try PEXParserStorageSize.add(output, capacitorNames)
        output = try PEXParserStorageSize.add(output, connectionNames)
        output = try PEXParserStorageSize.add(output, netNames)
        output = try PEXParserStorageSize.add(output, identifiers)
        output = try PEXParserStorageSize.add(output, PEXParserStorageSize.dictionary(String.self, String.self, count: 4))
        try scope.reserve(kind: .retained, byteCount: UInt64(try PEXParserStorageSize.multiply(output, 2)))

        var maps = 0
        maps = try PEXParserStorageSize.add(maps, PEXParserStorageSize.dictionary(String.self, NetName.self, count: references))
        maps = try PEXParserStorageSize.add(maps, PEXParserStorageSize.dictionary(String.self, InstancePath.self, count: connections))
        maps = try PEXParserStorageSize.add(maps, PEXParserStorageSize.array(String.self, count: tree.ports.count))
        maps = try PEXParserStorageSize.add(maps, PEXParserStorageSize.dictionary(String.self, Point2D.self, count: tree.ports.count))
        maps = try PEXParserStorageSize.add(maps, PEXParserStorageSize.dictionary(NetName.self, Set<String>.self, count: references))
        // Global external inventory, local definitions, node collection, sorted
        // node names and final existing-net set each contain at most references.
        maps = try PEXParserStorageSize.add(maps,
            PEXParserStorageSize.multiply(PEXParserStorageSize.array(String.self, count: references), 5))
        let coordinateCount = try PEXParserStorageSize.add(tree.ports.count,
            PEXParserStorageSize.add(connections, coordinates))
        maps = try PEXParserStorageSize.add(maps, PEXParserStorageSize.dictionary(String.self, Point2D.self, count: coordinateCount))
        // Coupling key plus dictionary-of-array header, stored pending rows and
        // one COW pending-array replacement coexist during reciprocal matching.
        maps = try PEXParserStorageSize.add(maps,
            PEXParserStorageSize.dictionary(CouplingEndpointPair.self, [PendingCoupling].self, count: elements))
        maps = try PEXParserStorageSize.add(maps,
            PEXParserStorageSize.multiply(PEXParserStorageSize.array(PendingCoupling.self, count: elements), 2))
        maps = try PEXParserStorageSize.add(maps,
            PEXParserStorageSize.array(String.self, count: try PEXParserStorageSize.add(longest, 1)))
        var text = 0
        // Distinct owner-map, local-set and collection-set resolved spellings.
        text = try PEXParserStorageSize.add(text, PEXParserStorageSize.multiply(names, 3))
        text = try PEXParserStorageSize.add(text, PEXParserStorageSize.multiply(portNames, 2))
        text = try PEXParserStorageSize.add(text, PEXParserStorageSize.multiply(connectionNames, 2))
        text = try PEXParserStorageSize.add(text, PEXParserStorageSize.multiply(longest, 2))
        try scope.reserve(kind: .temporary, byteCount: UInt64(
            try PEXParserStorageSize.multiply(PEXParserStorageSize.add(maps, text), 2)))
    }

    /// Bound the original decimal name-map lookup without materializing components.
    /// The suffix bound includes every byte after the first literal colon, so a
    /// colon inside a larger grapheme cannot underestimate the legacy suffix.
    static func resolvedNameByteCount(_ name: String, nameMap: [Int: String],
                                     scope: PEXParserResourceScope? = nil) throws -> Int {
        guard name.hasPrefix("*") else { return name.utf8.count }
        let rest = name.dropFirst()
        var offset = 0, digits = 0
        var negative = false
        var magnitude: UInt = 0
        var suffixBytes = 0
        for byte in rest.utf8 {
            try scope?.check()
            if byte == 58 {
                suffixBytes = rest.utf8.count - offset
                break
            }
            if offset == 0 && (byte == 43 || byte == 45) {
                negative = byte == 45
                offset += 1
                continue
            }
            guard byte >= 48 && byte <= 57 else { return name.utf8.count }
            let digit = UInt(byte - 48)
            let limit = UInt(Int.max) + (negative ? 1 : 0)
            guard magnitude <= (limit - digit) / 10 else { return name.utf8.count }
            magnitude = magnitude * 10 + digit
            digits += 1; offset += 1
        }
        guard digits > 0 else { return name.utf8.count }
        let identifier = negative
            ? (magnitude == UInt(Int.max) + 1 ? Int.min : -Int(magnitude))
            : Int(magnitude)
        guard let resolved = nameMap[identifier] else { return name.utf8.count }
        return try PEXParserStorageSize.add(resolved.utf8.count, suffixBytes)
    }
}
