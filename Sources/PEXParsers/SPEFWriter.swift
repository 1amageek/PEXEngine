import Foundation
import PEXCore

public struct SPEFWriter: Sendable {
    private let options: SPEFWriterOptions

    public init(options: SPEFWriterOptions = SPEFWriterOptions()) {
        self.options = options
    }

    public func write(_ ir: ParasiticIR) throws -> String {
        try validateHeaderIdentifiers()

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

        let ports = try portNodes(in: ir)
        if !ports.isEmpty {
            lines.append("*PORTS")
            for port in ports {
                lines.append("\(try identifier(port.name.value)) B")
            }
            lines.append("")
        }

        for net in ir.nets.sorted(by: { $0.name.value < $1.name.value }) {
            try appendNet(net, ir: ir, lines: &lines)
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

    private func appendNet(_ net: ParasiticNet, ir: ParasiticIR, lines: inout [String]) throws {
        let netName = try identifier(net.name.value)
        let elements = elements(for: net.name, in: ir.elements)
        let totalCapF = totalCapacitance(for: net, elements: elements)
        lines.append("*D_NET \(netName) \(formatCapacitance(totalCapF))")

        let connections = net.nodes.filter { $0.kind == .pin }.sorted { $0.name.value < $1.name.value }
        if !connections.isEmpty {
            lines.append("*CONN")
            for node in connections {
                let marker = node.name.value.contains(options.delimiter) ? "I" : "P"
                lines.append("*\(marker) \(try identifier(node.name.value)) B")
            }
        }

        let capacitors = capacitorEntries(for: net.name, elements: elements)
        if !capacitors.isEmpty {
            lines.append("*CAP")
            for (index, element) in capacitors.enumerated() {
                try appendCapacitor(element, index: index + 1, lines: &lines)
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
                    "\(index + 1) \(try nodeToken(element.nodeA)) \(try nodeToken(nodeB)) \(formatResistance(element.value))"
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
            case .resistor:
                return false
            }
        }.sorted { $0.id < $1.id }
    }

    private func appendCapacitor(_ element: ParasiticElement, index: Int, lines: inout [String]) throws {
        try validateFinite(id: element.id, value: element.value)
        if let nodeB = element.nodeB {
            lines.append(
                "\(index) \(try nodeToken(element.nodeA)) \(try nodeToken(nodeB)) \(formatCapacitance(element.value))"
            )
        } else {
            lines.append("\(index) \(try nodeToken(element.nodeA)) \(formatCapacitance(element.value))")
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
            case .resistor:
                return partial
            }
        }
    }

    private func nodeToken(_ ref: NodeRef) throws -> String {
        if isValidIdentifier(ref.nodeName.value) {
            return ref.nodeName.value
        }
        return try identifier("\(ref.netName.value)\(options.delimiter)\(ref.nodeName.value)")
    }

    private func portNodes(in ir: ParasiticIR) throws -> [ParasiticNode] {
        var seen: Set<NodeName> = []
        var ports: [ParasiticNode] = []
        for net in ir.nets {
            for node in net.nodes where node.kind == .pin && !node.name.value.contains(options.delimiter) {
                if seen.insert(node.name).inserted {
                    _ = try identifier(node.name.value)
                    ports.append(node)
                }
            }
        }
        return ports.sorted { $0.name.value < $1.name.value }
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

    private func format(_ value: Double) -> String {
        String(format: "%.12g", value)
    }

    private func escapedString(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
