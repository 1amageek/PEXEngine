import Foundation
import PEXCore

public struct SPEFWriter: Sendable {
    private let options: SPEFWriterOptions

    public init(options: SPEFWriterOptions = SPEFWriterOptions()) {
        self.options = options
    }

    public func write(_ ir: ParasiticIR) throws -> String {
        try validateHeaderIdentifiers()
        try validateGraph(ir)
        let nameMap = try makeNameMap(for: ir)
        let incidentCapacitances = try incidentCapacitances(in: ir)

        var lines: [String] = []
        lines.append("*SPEF \"\(escapedString(options.spefVersion))\"")
        lines.append("*DESIGN \"\(escapedString(designName(from: ir)))\"")
        lines.append("*DATE \"\(escapedString(options.date))\"")
        lines.append("*VENDOR \"\(escapedString(options.vendor))\"")
        let profile = options.terminalTokenProfile == .canonical ? " PEX_CANONICAL_TERMINALS_V1" : ""
        lines.append("*PROGRAM \"\(escapedString(options.program + profile + " PEX_IDENTITY_V1"))\"")
        lines.append("*VERSION \"\(escapedString(ir.version))\"")
        lines.append("*DESIGN_FLOW \"EXTERNAL\"")
        lines.append("*DIVIDER \(options.divider)")
        lines.append("*DELIMITER \(options.delimiter)")
        lines.append("*BUS_DELIMITER \(options.busDelimiterOpen) \(options.busDelimiterClose)")
        lines.append("*T_UNIT 1 NS")
        lines.append("*C_UNIT 1 \(options.capacitanceUnit.rawValue)")
        lines.append("*R_UNIT 1 \(options.resistanceUnit.rawValue)")
        lines.append("*L_UNIT 1 HENRY")
        lines.append("")

        if !nameMap.entries.isEmpty {
            lines.append("*NAME_MAP")
            for entry in nameMap.entries {
                lines.append("*\(entry.id) \(entry.name.replacingOccurrences(of: "-", with: "\\-"))")
            }
            lines.append("")
        }

        let ports = try portNodes(in: ir)
        if !ports.isEmpty {
            lines.append("*PORTS")
            for port in ports {
                lines.append("\(try localNodeToken(port.ref, nameMap: nameMap)) B\(coordinateSuffix(port.node.coordinate))")
            }
            lines.append("")
        }

        for net in ir.nets.sorted(by: { $0.name.value < $1.name.value }) {
            try appendNet(net, ir: ir, totalCapF: incidentCapacitances[net.name, default: 0], nameMap: nameMap, lines: &lines)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public func write(_ ir: ParasiticIR, to url: URL) throws {
        let spef = try write(ir)
        do {
            try Data(spef.utf8).write(to: url, options: .atomic)
        } catch {
            throw PEXError.persistenceFailed("Failed to write SPEF to \(url.path(percentEncoded: false))", underlying: error)
        }
    }

    private func appendNet(
        _ net: ParasiticNet,
        ir: ParasiticIR,
        totalCapF: Double,
        nameMap: SPEFNameMap,
        lines: inout [String]
    ) throws {
        let netName = try token(for: net.name.value, nameMap: nameMap)
        let elements = try elements(for: net.name, in: ir.elements).map { element in
            let scale: Double
            switch element.kind {
            case .resistor: scale = ir.units.resistance == .kiloOhm ? 1_000 : 1
            case .capacitor, .coupling:
                switch ir.units.capacitance {
                case .farad: scale = 1
                case .picoFarad: scale = 1e-12
                case .femtoFarad: scale = 1e-15
                }
            case .inductor: scale = 1
            }
            let value = element.value * scale
            try validateFinite(id: element.id, value: value)
            return ParasiticElement(id: element.id, kind: element.kind, nodeA: element.nodeA,
                                    nodeB: element.nodeB, value: value, source: element.source)
        }
        lines.append("*D_NET \(netName) \(formatCapacitance(totalCapF))")

        let connections = net.nodes.filter { $0.kind == .pin }.sorted { $0.name.value < $1.name.value }
        let nodeCoordinates = net.nodes
            .filter { $0.kind != .pin && $0.coordinate != nil }
            .sorted { $0.name.value < $1.name.value }
        if !connections.isEmpty {
            lines.append("*CONN")
            for node in connections {
                let marker = node.instancePath == nil ? "P" : "I"
                lines.append("*\(marker) \(try localNodeToken(NodeRef(netName: net.name, nodeName: node.name), nameMap: nameMap)) B\(coordinateSuffix(node.coordinate))")
            }
            for node in nodeCoordinates {
                lines.append("*N \(try localNodeToken(NodeRef(netName: net.name, nodeName: node.name), nameMap: nameMap))\(coordinateSuffix(node.coordinate))")
            }
        }

        let capacitors = capacitorEntries(for: net.name, elements: elements)
        if !capacitors.isEmpty {
            lines.append("*CAP")
            for (index, element) in capacitors.enumerated() {
                try appendCapacitor(element, currentNetName: net.name, index: index + 1, nameMap: nameMap, lines: &lines)
            }
        }

        let resistors = elements.filter { $0.kind == .resistor }.sorted { $0.id < $1.id }
        if !resistors.isEmpty {
            lines.append("*RES")
            for (index, element) in resistors.enumerated() {
                guard let nodeB = element.nodeB else {
                    throw SPEFWriterError.missingResistorEndpoint(id: element.id)
                }
                try validateFinite(id: element.id, value: element.value)
                lines.append(
                    "\(index + 1) \(try localNodeToken(element.nodeA, nameMap: nameMap)) \(try localNodeToken(nodeB, nameMap: nameMap)) \(formatResistance(element.value))"
                )
            }
        }

        let inductors = elements.filter { $0.kind == .inductor }.sorted { $0.id < $1.id }
        if !inductors.isEmpty {
            lines.append("*INDUC")
            for (index, element) in inductors.enumerated() {
                guard let nodeB = element.nodeB else {
                    throw SPEFWriterError.missingInductorEndpoint(id: element.id)
                }
                try validateFinite(id: element.id, value: element.value)
                lines.append(
                    "\(index + 1) \(try localNodeToken(element.nodeA, nameMap: nameMap)) \(try localNodeToken(nodeB, nameMap: nameMap)) \(formatInductance(element.value))"
                )
            }
        }

        lines.append("*END")
        lines.append("")
    }

    private func elements(for netName: NetName, in elements: [ParasiticElement]) -> [ParasiticElement] {
        elements.filter { element in
            element.nodeA.netName == netName
        }
    }

    private func capacitorEntries(for netName: NetName, elements: [ParasiticElement]) -> [ParasiticElement] {
        elements.filter { element in
            switch element.kind {
            case .capacitor:
                return true
            case .coupling:
                return element.nodeA.netName == netName
            case .resistor, .inductor:
                return false
            }
        }.sorted { $0.id < $1.id }
    }

    private func appendCapacitor(
        _ element: ParasiticElement,
        currentNetName: NetName,
        index: Int,
        nameMap: SPEFNameMap,
        lines: inout [String]
    ) throws {
        try validateFinite(id: element.id, value: element.value)
        if let nodeB = element.nodeB {
            lines.append(
                "\(index) \(try localNodeToken(element.nodeA, nameMap: nameMap)) \(try capacitorEndpointToken(nodeB, currentNetName: currentNetName, nameMap: nameMap)) \(formatCapacitance(element.value))"
            )
        } else {
            lines.append("\(index) \(try localNodeToken(element.nodeA, nameMap: nameMap)) \(formatCapacitance(element.value))")
        }
    }

    private func incidentCapacitances(in ir: ParasiticIR) throws -> [NetName: Double] {
        let scale: Double
        switch ir.units.capacitance {
        case .farad: scale = 1
        case .picoFarad: scale = 1e-12
        case .femtoFarad: scale = 1e-15
        }
        var totals: [NetName: Double] = [:]
        func add(_ value: Double, to net: NetName) throws {
            let total = totals[net, default: 0] + value
            try validateFinite(id: net.value, value: total)
            let outputTotal = total / options.capacitanceUnit.faradsPerUnit
            try validateFinite(id: net.value, value: outputTotal)
            guard total == 0 || outputTotal > 0 else {
                throw SPEFWriterError.unrepresentableTopology(id: net.value, reason: "Positive capacitance underflows in output units")
            }
            totals[net] = total
        }
        // Header totals describe incident CAP operators, not nodeA-owned IR inventory.
        for element in ir.elements.sorted(by: { $0.id < $1.id }) {
            guard element.kind == .capacitor || element.kind == .coupling else { continue }
            let value = element.value * scale
            try validateFinite(id: element.id, value: value)
            guard element.value == 0 || value > 0 else {
                throw SPEFWriterError.unrepresentableTopology(id: element.id, reason: "Positive capacitance underflows in canonical units")
            }
            try add(value, to: element.nodeA.netName)
            if let nodeB = element.nodeB, nodeB.netName != element.nodeA.netName {
                try add(value, to: nodeB.netName)
            }
        }
        return totals
    }

    private func localNodeToken(_ ref: NodeRef, nameMap: SPEFNameMap) throws -> String {
        guard let value = nameMap.nodeTokens[ref] else { throw SPEFWriterError.invalidIdentifier("Dangling scoped node") }
        return try token(for: value, nameMap: nameMap)
    }

    private func capacitorEndpointToken(_ ref: NodeRef, currentNetName: NetName, nameMap: SPEFNameMap) throws -> String {
        try localNodeToken(ref, nameMap: nameMap)
    }

    private func portNodes(in ir: ParasiticIR) throws -> [(ref: NodeRef, node: ParasiticNode)] {
        ir.nets.flatMap { net in
            net.nodes.filter { $0.kind == .pin && $0.instancePath == nil }.map { (NodeRef(netName: net.name, nodeName: $0.name), $0) }
        }.sorted { $0.ref.netName.value + ":" + $0.ref.nodeName.value < $1.ref.netName.value + ":" + $1.ref.nodeName.value }
    }

    private func validateGraph(_ ir: ParasiticIR) throws {
        let refs = ir.nets.flatMap { net in net.nodes.map { NodeRef(netName: net.name, nodeName: $0.name) } }
        guard Set(ir.nets.map(\.name)).count == ir.nets.count, Set(refs).count == refs.count,
              Set(ir.elements.map(\.id)).count == ir.elements.count else {
            throw SPEFWriterError.invalidIdentifier("Duplicate canonical identity")
        }
        let known = Set(refs)
        guard !(ir.metadata["referenceNodeName"] ?? "0").isEmpty else {
            throw SPEFWriterError.invalidIdentifier("Empty model reference")
        }
        for net in ir.nets {
            guard net.nodes.allSatisfy({ $0.coordinate.map { $0.x.isFinite && $0.y.isFinite } ?? true }) else {
                throw SPEFWriterError.invalidIdentifier("Invalid node coordinates in " + net.name.value)
            }
            guard net.totalGroundCapF.isFinite, net.totalCouplingCapF.isFinite, net.totalResistanceOhm.isFinite,
                  net.totalGroundCapF >= 0, net.totalCouplingCapF >= 0, net.totalResistanceOhm >= 0 else {
                throw SPEFWriterError.invalidIdentifier("Invalid net inventory " + net.name.value)
            }
        }
        for element in ir.elements {
            guard known.contains(element.nodeA), element.nodeB.map({ known.contains($0) }) ?? true else {
                throw SPEFWriterError.invalidIdentifier("Dangling endpoint for " + element.id)
            }
            guard element.value.isFinite, element.value >= 0 else {
                throw SPEFWriterError.nonFiniteValue(id: element.id, value: element.value)
            }
            if (element.kind == .resistor || element.kind == .inductor),
               let b = element.nodeB, b.netName != element.nodeA.netName {
                throw SPEFWriterError.unrepresentableTopology(id: element.id, reason: "Cross-net resistance or inductance is not an intra-net SPEF network")
            }
            if element.kind == .coupling && element.nodeB == nil {
                throw SPEFWriterError.unrepresentableTopology(id: element.id, reason: "Coupling requires two exact endpoints")
            }
            if element.kind == .capacitor && element.nodeB == nil,
               let reference = ir.metadata["referenceNodeName"], reference != "0" {
                throw SPEFWriterError.unrepresentableTopology(id: element.id, reason: "SPEF implicit reference cannot bind the explicit model reference " + reference)
            }
        }
    }

    private func coordinateSuffix(_ coordinate: Point2D?) -> String {
        guard let coordinate else { return "" }
        return " *C \(formatCoordinate(coordinate.x)) \(formatCoordinate(coordinate.y))"
    }

    private func designName(from ir: ParasiticIR) -> String {
        ir.metadata["designName"] ?? ir.metadata["topCell"] ?? options.designName
    }

    private func validateHeaderIdentifiers() throws {
        _ = try identifier(options.divider)
        _ = try identifier(options.delimiter)
        _ = try identifier(options.busDelimiterOpen)
        _ = try identifier(options.busDelimiterClose)
    }

    private func token(for value: String, nameMap: SPEFNameMap) throws -> String {
        if let id = nameMap.id(for: value) {
            return "*\(id)"
        }
        return try identifier(value)
    }

    private func makeNameMap(for ir: ParasiticIR) throws -> SPEFNameMap {
        var names: Set<String> = []
        var tokens: [NodeRef: String] = [:]
        var identityNodes: [String: PEXSPICEIdentity.Node] = [:]
        let netRoots = Set(ir.nets.map { $0.name.value })
        for net in ir.nets {
            try validateWritableName(net.name.value)
            if options.terminalTokenProfile == .canonical { try validateCanonicalToken(net.name.value) }
            collectWritableName(net.name.value, into: &names)
            for (index, node) in net.nodes.sorted(by: { $0.name.value < $1.name.value }).enumerated() {
                let ref = NodeRef(netName: net.name, nodeName: node.name)
                var pin = options.terminalTokenProfile == .canonical ? node.name.value
                    : "PEX_PIN_" + PEXSPICEIdentity.hex(net.name.value) + "_" + PEXSPICEIdentity.hex(node.name.value)
                if node.kind == .pin, let path = node.instancePath {
                    let prefix = path.value + options.delimiter
                    guard !path.value.isEmpty, !options.delimiter.isEmpty,
                          node.name.value.hasPrefix(prefix) else {
                        throw SPEFWriterError.invalidIdentifier("Instance pin name disagrees with its declared instance path")
                    }
                    let leaf = node.name.value.dropFirst(prefix.count)
                    guard !leaf.isEmpty, !leaf.contains(options.delimiter) else {
                        throw SPEFWriterError.invalidIdentifier("Instance pin requires one exact pin leaf after the delimiter")
                    }
                    if options.terminalTokenProfile != .canonical {
                        pin = "PEX_INSTANCE_" + PEXSPICEIdentity.hex(path.value) + options.delimiter + pin
                    }
                }
                let value = node.kind == .pin ? pin
                    : net.name.value + options.delimiter + String(index + 1)
                try validateWritableName(value)
                guard !net.name.value.isEmpty, !node.name.value.isEmpty, identityNodes[value] == nil else {
                    throw SPEFWriterError.invalidIdentifier("Noninjective scoped node token")
                }
                if options.terminalTokenProfile == .canonical {
                    try validateCanonicalToken(value)
                    guard value != "0", !netRoots.contains(value) || (node.kind == .pin && value == net.name.value) else {
                        throw SPEFWriterError.invalidIdentifier("Ambiguous canonical terminal or internal token")
                    }
                }
                tokens[ref] = value
                identityNodes[value] = .init(ref: ref, kind: node.kind, instancePath: node.kind == .pin ? node.instancePath : nil)
                collectWritableName(value, into: &names)
            }
        }
        var kinds: [String: ElementKind] = [:]
        for net in ir.nets {
            let local = elements(for: net.name, in: ir.elements)
            for (index, element) in capacitorEntries(for: net.name, elements: local).enumerated() {
                kinds[net.name.value + "_C" + String(index + 1)] = element.kind
            }
            for (index, element) in local.filter({ $0.kind == .resistor }).sorted(by: { $0.id < $1.id }).enumerated() {
                kinds[net.name.value + "_R" + String(index + 1)] = element.kind
            }
            for (index, element) in local.filter({ $0.kind == .inductor }).sorted(by: { $0.id < $1.id }).enumerated() {
                kinds[net.name.value + "_L" + String(index + 1)] = element.kind
            }
        }
        let identity = PEXSPICEIdentity(nodes: identityNodes, elementKinds: kinds,
                                       referenceName: ir.metadata["referenceNodeName"] ?? "0", referenceToken: "0",
                                       canonicalTerminals: options.terminalTokenProfile == .canonical ? true : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let annotation = "PEX_IDENTITY_V1_" + (try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
        let entries = [SPEFNameMapEntry(id: 1, name: annotation)] + (try names.sorted().enumerated().map { index, name in
            try validateWritableName(name)
            return SPEFNameMapEntry(id: index + 2, name: name)
        })
        return SPEFNameMap(entries: entries, nodeTokens: tokens)
    }

    private func collectWritableName(_ value: String, into names: inout Set<String>) {
        if !isValidIdentifier(value) {
            names.insert(value)
        }
    }

    private func validateCanonicalToken(_ value: String) throws {
        guard let first = value.first, first.isLetter || first == "_" || first == "$" || first == "#",
              !value.contains("\\"), !value.hasPrefix("PEX_IDENTITY_V1_") else {
            throw SPEFWriterError.invalidIdentifier("Canonical SPEF token is outside the lossless parser subset: " + value)
        }
    }

    private func validateWritableName(_ value: String) throws {
        if isValidIdentifier(value) {
            return
        }
        guard isValidNameMapValue(value) else {
            throw SPEFWriterError.invalidIdentifier(value)
        }
    }

    private func identifier(_ value: String) throws -> String {
        guard isValidIdentifier(value) else {
            throw SPEFWriterError.invalidIdentifier(value)
        }
        return value
    }

    private func isValidIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }
        let scalars = Array(value.unicodeScalars)
        let first = scalars[0]
        let firstAllowed = CharacterSet.letters.contains(first)
            || first == "_"
            || first == "\\"
            || first == "/"
            || first == ":"
            || first == "["
            || first == "]"
        guard firstAllowed else {
            return false
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./:\\[]"))
        return scalars.allSatisfy { allowed.contains($0) }
    }

    private func isValidNameMapValue(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || value.contains("\"") {
            return false
        }
        // A literal backslash cannot also introduce the emitted hyphen escape.
        if value.contains("-") && value.contains("\\") { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./:\\[]$#-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func validateFinite(id: String, value: Double) throws {
        guard value.isFinite else {
            throw SPEFWriterError.nonFiniteValue(id: id, value: value)
        }
    }

    private func formatCapacitance(_ value: Double) -> String {
        format(value / options.capacitanceUnit.faradsPerUnit)
    }

    private func formatResistance(_ value: Double) -> String {
        format(value / options.resistanceUnit.ohmsPerUnit)
    }

    private func formatInductance(_ value: Double) -> String {
        format(value)
    }

    private func formatCoordinate(_ value: Double) -> String {
        format(value)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.12g", value)
    }

    private func escapedString(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private struct SPEFNameMapEntry: Sendable, Hashable {
    let id: Int
    let name: String
}

private struct SPEFNameMap: Sendable, Hashable {
    let entries: [SPEFNameMapEntry]
    let nodeTokens: [NodeRef: String]
    private let idsByName: [String: Int]

    init(entries: [SPEFNameMapEntry], nodeTokens: [NodeRef: String]) {
        self.nodeTokens = nodeTokens
        self.entries = entries
        var ids: [String: Int] = [:]
        for entry in entries {
            ids[entry.name] = entry.id
        }
        self.idsByName = ids
    }

    func id(for name: String) -> Int? {
        idsByName[name]
    }
}
