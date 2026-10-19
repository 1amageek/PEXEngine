import CircuiteFoundation
import DEF
import LEF
import LogicDesignSerialization

extension NativeRoutedPEXStandardGeometry {
    private struct SourceTerminal: Hashable {
        let instance: String?
        let pin: String
    }

    mutating func joinSource(_ structural: StructuralVerilogSource, sourceReference: ArtifactReference,
                             isCancelled: () -> Bool)
        throws(NativeRoutedPEXPreparationError) -> NativeRoutedPEXSourceJoinEvidence {
        try budget.visit(isCancelled: isCancelled)
        guard structural.top == source.designName, structural.instances.count == components.count else {
            throw .sourceMismatch("Structural top or complete instance inventory differs from DEF")
        }
        var canonicalNames: [String: String] = [:]
        for net in structural.nets {
            try budget.visit(isCancelled: isCancelled); try budget.record()
            guard canonicalNames.updateValue(net.canonicalName, forKey: net.name) == nil else {
                throw .sourceMismatch("Duplicate structural net identity")
            }
        }
        var expected: [SourceTerminal: String] = [:]
        var instances = Set<String>()
        for instance in structural.instances {
            try budget.visit(isCancelled: isCancelled); try budget.record()
            guard instances.insert(instance.name).inserted, let component = components[instance.name],
                  component.macro == instance.cellName, let master = masters[instance.cellName] else {
                throw .sourceMismatch("Structural instance/master identity differs from DEF and LEF")
            }
            var signalPins = Set<String>()
            for pin in master.definition.pins where pin.use != .power && pin.use != .ground {
                try budget.visit(isCancelled: isCancelled); try budget.record()
                guard signalPins.insert(pin.name).inserted else { throw .sourceMismatch("Duplicate LEF signal pin") }
            }
            guard instance.connections.count == signalPins.count else {
                throw .sourceMismatch("Structural named pins do not cover the exact LEF signal-pin inventory")
            }
            for pin in instance.connections {
                try budget.visit(isCancelled: isCancelled); try budget.record()
                guard signalPins.remove(pin.pinName) != nil,
                      expected.updateValue(pin.canonicalNetName,
                        forKey: .init(instance: instance.name, pin: pin.pinName)) == nil else {
                    throw .sourceMismatch("Foreign or duplicate structural signal-pin connection")
                }
            }
        }
        var signalPortCount = 0
        for port in ports.values where port.use != .power && port.use != .ground {
            try budget.visit(isCancelled: isCancelled)
            signalPortCount += 1
        }
        guard structural.ports.count == signalPortCount else {
            throw .sourceMismatch("Structural root ports differ from the exact DEF signal-port inventory")
        }
        for port in structural.ports {
            try budget.visit(isCancelled: isCancelled); try budget.record()
            guard let actual = ports[port.name], actual.use != .power && actual.use != .ground else {
                throw .sourceMismatch("Structural port identity differs from DEF")
            }
            let sameDirection: Bool
            switch (port.direction, actual.direction) {
            case (.input, .some(.input)), (.output, .some(.output)): sameDirection = true
            default: sameDirection = false
            }
            guard sameDirection,
                  expected.updateValue(port.netName, forKey: .init(instance: nil, pin: port.name)) == nil else {
                throw .sourceMismatch("Structural port direction or uniqueness differs from DEF")
            }
        }
        let (netCount, overflow) = source.nets.count.addingReportingOverflow(source.specialNets.count)
        guard !overflow else { throw .arithmeticOverflow }
        try budget.record(netCount)
        let defNets = source.nets.map { ($0.name, $0.use, $0.connections) }
            + source.specialNets.map { ($0.name, $0.use, $0.connections) }
        var seen = Set<SourceTerminal>(), claimed = Set<String>()
        var observations: [NativeRoutedPEXSourceJoinEvidence.Net] = []
        for (name, use, connections) in defNets {
            try budget.visit(isCancelled: isCancelled)
            guard use != .power && use != .ground else { continue }
            guard let canonical = canonicalNames[name], claimed.insert(canonical).inserted else {
                throw .sourceMismatch("DEF signal net is foreign or partitions one source alias component")
            }
            try budget.record()
            var names: [String] = []
            for connection in connections {
                try budget.visit(isCancelled: isCancelled); try budget.record(2)
                let terminal = SourceTerminal(instance: connection.componentName == "PIN" ? nil : connection.componentName,
                    pin: connection.pinName)
                guard expected[terminal] == canonical, seen.insert(terminal).inserted else {
                    throw .sourceMismatch("Saved DEF and structural source disagree on exact terminal connectivity")
                }
                names.append(try terminalName(connection))
            }
            observations.append(.init(defNetName: name, canonicalSourceNetName: canonical, terminalNames: names))
        }
        guard seen.count == expected.count else {
            throw .sourceMismatch("Saved DEF omits structural source signal terminals")
        }
        return .init(topCell: structural.top, defArtifactID: defReference.id,
            sourceNetlistArtifactID: sourceReference.id, instanceCount: instances.count, nets: observations)
    }
}
