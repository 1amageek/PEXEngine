import Foundation
import PEXCore

public struct SPEFWriter: Sendable {
    private let options: SPEFWriterOptions

    public init(options: SPEFWriterOptions = SPEFWriterOptions()) {
        self.options = options
    }

    public func write(_ ir: ParasiticIR) throws -> String {
        try validateHeaderIdentifiers()
        let nameMap = try makeNameMap(for: ir)

        var lines: [String] = []
        lines.append("*SPEF \"\(escapedString(options.spefVersion))\"")
        lines.append("*DESIGN \"\(escapedString(designName(from: ir)))\"")
        lines.append("*DATE \"\(escapedString(options.date))\"")
        lines.append("*VENDOR \"\(escapedString(options.vendor))\"")
        lines.append("*PROGRAM \"\(escapedString(options.program))\"")
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
                lines.append("*\(entry.id) \(entry.name)")
            }
            lines.append("")
        }

        let ports = try portNodes(in: ir)
        if !ports.isEmpty {
            lines.append("*PORTS")
            for port in ports {
                lines.append("\(try token(for: port.name.value, nameMap: nameMap)) B\(coordinateSuffix(port.coordinate))")
            }
            lines.append("")
        }

        for net in ir.nets.sorted(by: { $0.name.value < $1.name.value }) {
            try appendNet(net, ir: ir, nameMap: nameMap, lines: &lines)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public func write(_ ir: ParasiticIR, to url: URL) throws {
        let spef = try write(ir)
        do {
            try Data(spef.utf8).write(to: url)
        } catch {
            throw PEXError.persistenceFailed("Failed to write SPEF to \(url.path(percentEncoded: false))", underlying: error)
        }
    }

    private func appendNet(
        _ net: ParasiticNet,
        ir: ParasiticIR,
        nameMap: SPEFNameMap,
        lines: inout [String]
    ) throws {
        let netName = try token(for: net.name.value, nameMap: nameMap)
        let elements = elements(for: net.name, in: ir.elements)
        let totalCapF = totalCapacitance(for: net, elements: elements)
        lines.append("*D_NET \(netName) \(formatCapacitance(totalCapF))")

        let connections = net.nodes.filter { $0.kind == .pin }.sorted { $0.name.value < $1.name.value }
        let nodeCoordinates = net.nodes
            .filter { $0.kind != .pin && $0.coordinate != nil }
            .sorted { $0.name.value < $1.name.value }
        if !connections.isEmpty || !nodeCoordinates.isEmpty {
            lines.append("*CONN")
            for node in connections {
                let marker = node.name.value.contains(options.delimiter) ? "I" : "P"
                lines.append("*\(marker) \(try token(for: node.name.value, nameMap: nameMap)) B\(coordinateSuffix(node.coordinate))")
            }
            for node in nodeCoordinates {
                lines.append("*N \(try token(for: node.name.value, nameMap: nameMap))\(coordinateSuffix(node.coordinate))")
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

    private func totalCapacitance(for net: ParasiticNet, elements: [ParasiticElement]) -> Double {
        let declared = net.totalGroundCapF + net.totalCouplingCapF
        if declared > 0 {
            return declared
        }
        return elements.reduce(0) { partial, element in
            switch element.kind {
            case .capacitor, .coupling:
                return partial + element.value
            case .resistor, .inductor:
                return partial
            }
        }
    }

    private func localNodeToken(_ ref: NodeRef, nameMap: SPEFNameMap) throws -> String {
        try token(for: ref.nodeName.value, nameMap: nameMap)
    }

    private func capacitorEndpointToken(_ ref: NodeRef, currentNetName: NetName, nameMap: SPEFNameMap) throws -> String {
        if ref.netName == currentNetName || ref.nodeName.value.contains(options.delimiter) {
            return try localNodeToken(ref, nameMap: nameMap)
        }
        return try token(for: "\(ref.netName.value)\(options.delimiter)\(ref.nodeName.value)", nameMap: nameMap)
    }

    private func portNodes(in ir: ParasiticIR) throws -> [ParasiticNode] {
        var seen: Set<NodeName> = []
        var ports: [ParasiticNode] = []
        for net in ir.nets {
            for node in net.nodes where node.kind == .pin && !node.name.value.contains(options.delimiter) {
                if seen.insert(node.name).inserted {
                    try validateWritableName(node.name.value)
                    ports.append(node)
                }
            }
        }
        return ports.sorted { $0.name.value < $1.name.value }
    }

    private func coordinateSuffix(_ coordinate: Point2D?) -> String {
        guard let coordinate else { return "" }
        return " \(formatCoordinate(coordinate.x)) \(formatCoordinate(coordinate.y))"
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
        for net in ir.nets {
            collectWritableName(net.name.value, into: &names)
            for node in net.nodes {
                collectWritableName(node.name.value, into: &names)
            }
        }
        for element in ir.elements {
            collectWritableName(element.nodeA.netName.value, into: &names)
            collectWritableName(element.nodeA.nodeName.value, into: &names)
            if let nodeB = element.nodeB {
                collectWritableName(nodeB.netName.value, into: &names)
                collectWritableName(nodeB.nodeName.value, into: &names)
                if nodeB.netName != element.nodeA.netName && !nodeB.nodeName.value.contains(options.delimiter) {
                    collectWritableName("\(nodeB.netName.value)\(options.delimiter)\(nodeB.nodeName.value)", into: &names)
                }
            }
        }

        let ordered = try names.sorted().enumerated().map { index, name in
            try validateWritableName(name)
            return SPEFNameMapEntry(id: index + 1, name: name)
        }
        return SPEFNameMap(entries: ordered)
    }

    private func collectWritableName(_ value: String, into names: inout Set<String>) {
        if !isValidIdentifier(value) {
            names.insert(value)
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
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./:\\[]$#"))
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
    private let idsByName: [String: Int]

    init(entries: [SPEFNameMapEntry]) {
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
