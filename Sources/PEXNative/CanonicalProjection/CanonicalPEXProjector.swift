import Foundation
import LayoutVerify
import PEXCore

public struct CanonicalPEXProjector: NativePEXProjecting {
    public init() {}

    private struct ScopedNet: Hashable {
        let occurrence: Int
        let id: UUID
        init(_ reference: LayoutConductorSnapshot.NetReference) { occurrence = reference.occurrenceIndex; id = reference.netID }
        init(_ binding: NativePEXNetBinding) { occurrence = binding.occurrenceIndex; id = binding.netID }
    }
    private struct Bucket {
        var nodes: [ParasiticNode] = []
        var ground = 0.0
        var coupling = 0.0
        var resistance = 0.0
    }

    public func project(electrodes: NativePEXElectrodeNetwork, netBindings: [NativePEXNetBinding],
                        limits: NativePEXProjectionLimits = .default,
                        isCancelled: () -> Bool = { Task.isCancelled })
        throws(NativePEXProjectionError) -> NativePEXProjection {
        var budget = try NativePEXProjectionBudget(limits)
        try budget.visit(isCancelled)
        let network = electrodes.network, snapshot = network.snapshot
        for count in [snapshot.footprints.count, snapshot.components.count, snapshot.pins.count,
                      snapshot.opens.count, netBindings.count, electrodes.ports.count, electrodes.contacts.count,
                      network.nodes.count, network.resistors.count, network.capacitors.count] {
            try budget.charge(.inputRecords, count)
        }
        try budget.charge(.nodes, network.nodes.count)
        try budget.charge(.nodes, electrodes.ports.count)
        try budget.charge(.elements, network.resistors.count)
        try budget.charge(.elements, electrodes.contacts.count)
        try budget.charge(.elements, network.capacitors.count)
        try budget.identifier(network.model.referenceNodeName, isCancelled)
        try budget.identifier(network.model.cornerID.value, isCancelled)
        guard electrodes.ports.count == snapshot.pins.count else { throw .invalidNetwork }

        var references: [ScopedNet] = [], expected: Set<ScopedNet> = []
        func admit(_ reference: LayoutConductorSnapshot.NetReference) throws(NativePEXProjectionError) {
            try budget.visit(isCancelled)
            guard snapshot.hierarchy.occurrences.indices.contains(reference.occurrenceIndex) else { throw .invalidNetwork }
            let key = ScopedNet(reference)
            if expected.insert(key).inserted { references.append(key) }
        }
        for footprint in snapshot.footprints {
            try budget.visit(isCancelled)
            if let ref = footprint.declaredNet { try admit(ref) }
        }
        for component in snapshot.components {
            try budget.visit(isCancelled)
            try budget.charge(.inputRecords, component.declaredNets.count)
            for ref in component.declaredNets { try admit(ref) }
        }
        for pin in snapshot.pins {
            try budget.visit(isCancelled)
            if let ref = pin.declaredNet { try admit(ref) }
        }
        for open in snapshot.opens { try admit(open.net) }

        var bindings: [ScopedNet: NativePEXNetBinding] = [:], netNames: Set<String> = []
        for binding in netBindings {
            try budget.visit(isCancelled)
            try budget.identifier(binding.netName.value, isCancelled)
            let key = ScopedNet(binding)
            guard expected.contains(key) else { throw .unknownBinding(occurrenceIndex: key.occurrence, netID: key.id) }
            guard bindings.updateValue(binding, forKey: key) == nil else {
                throw .duplicateBinding(occurrenceIndex: key.occurrence, netID: key.id)
            }
            guard netNames.insert(binding.netName.value).inserted else { throw .duplicateNetName(binding.netName.value) }
        }
        var normalized: [NativePEXNetBinding] = []
        for key in references {
            try budget.visit(isCancelled)
            guard let binding = bindings[key] else { throw .missingBinding(occurrenceIndex: key.occurrence, netID: key.id) }
            normalized.append(binding)
        }
        var sourceNames: Set<String> = [], sourceRefs: Set<NodeRef> = []
        for (index, port) in electrodes.ports.enumerated() {
            try budget.visit(isCancelled)
            try budget.identifier(port.terminal.netName.value, isCancelled)
            try budget.identifier(port.terminal.nodeName.value, isCancelled)
            guard port.pinIndex == index, sourceRefs.insert(port.terminal).inserted else { throw .invalidNetwork }
            if let reference = snapshot.pins[index].declaredNet {
                guard bindings[ScopedNet(reference)]?.netName == port.terminal.netName else { throw .terminalNetMismatch(pinIndex: index) }
            }
            if let component = port.componentIndex {
                guard snapshot.components.indices.contains(component), snapshot.pins[index].componentIndices == [component] else { throw .invalidNetwork }
            } else { guard snapshot.pins[index].componentIndices.isEmpty else { throw .invalidNetwork } }
            sourceNames.insert(port.terminal.nodeName.value); netNames.insert(port.terminal.netName.value)
        }

        var buckets: [NetName: Bucket] = [:]
        for name in netNames { try budget.visit(isCancelled); buckets[NetName(name)] = Bucket() }
        var componentNets: [NetName] = []
        for (index, component) in snapshot.components.enumerated() {
            try budget.visit(isCancelled)
            let owner: NetName
            if component.declaredNets.count == 1, let ref = component.declaredNets.first,
               let binding = bindings[ScopedNet(ref)] { owner = binding.netName }
            else {
                owner = NetName(try unique("__PEX_COMPONENT_\(index)", used: &netNames, budget: &budget, isCancelled: isCancelled))
                buckets[owner] = Bucket()
            }
            componentNets.append(owner)
        }
        let micrometersPerUnit = network.metersPerDatabaseUnit * 1e6
        guard micrometersPerUnit.isFinite, micrometersPerUnit > 0 else { throw .numericFailure }
        var numericRefs: [NodeRef] = []
        for (index, node) in network.nodes.enumerated() {
            try budget.visit(isCancelled)
            guard componentNets.indices.contains(node.componentIndex), node.minXDatabaseUnits < node.maxXDatabaseUnits,
                  node.minYDatabaseUnits < node.maxYDatabaseUnits else { throw .invalidNetwork }
            let name = NodeName(try unique("__PEX_NODE_\(index)", used: &sourceNames, budget: &budget, isCancelled: isCancelled))
            let coordinate = Point2D(x: (Double(node.minXDatabaseUnits) + Double(node.maxXDatabaseUnits)) * 0.5 * micrometersPerUnit,
                                     y: (Double(node.minYDatabaseUnits) + Double(node.maxYDatabaseUnits)) * 0.5 * micrometersPerUnit)
            guard coordinate.x.isFinite, coordinate.y.isFinite else { throw .numericFailure }
            let net = componentNets[node.componentIndex], ref = NodeRef(netName: net, nodeName: name)
            numericRefs.append(ref)
            buckets[net]!.nodes.append(.init(name: name, kind: .internal, instancePath: nil, coordinate: coordinate))
        }
        for port in electrodes.ports {
            try budget.visit(isCancelled)
            buckets[port.terminal.netName]!.nodes.append(.init(name: port.terminal.nodeName, kind: .pin, instancePath: nil, coordinate: nil))
        }

        var elements: [ParasiticElement] = []
        func emit(id: String, kind: ElementKind, a: NodeRef, b: NodeRef?, value: Double) throws(NativePEXProjectionError) {
            try budget.visit(isCancelled)
            guard value.isFinite, value > 0 else { throw .numericFailure }
            guard buckets[a.netName] != nil else { throw .invalidNetwork }
            switch kind {
            case .resistor: buckets[a.netName]!.resistance += value
            case .capacitor: buckets[a.netName]!.ground += value
            case .coupling: buckets[a.netName]!.coupling += value
            case .inductor: throw .invalidNetwork
            }
            guard let bucket = buckets[a.netName], bucket.ground.isFinite,
                  bucket.coupling.isFinite, bucket.resistance.isFinite else { throw .numericFailure }
            elements.append(.init(id: id, kind: kind, nodeA: a, nodeB: b, value: value, source: .calculated))
        }
        for (index, edge) in network.resistors.enumerated() {
            guard numericRefs.indices.contains(edge.nodeA), numericRefs.indices.contains(edge.nodeB), edge.nodeA != edge.nodeB,
                  network.nodes[edge.nodeA].componentIndex == network.nodes[edge.nodeB].componentIndex else { throw .invalidNetwork }
            try emit(id: "native.r.\(index)", kind: .resistor, a: numericRefs[edge.nodeA], b: numericRefs[edge.nodeB], value: edge.ohms)
        }
        for (index, edge) in electrodes.contacts.enumerated() {
            guard numericRefs.indices.contains(edge.nodeIndex), electrodes.ports.indices.contains(edge.portIndex),
                  electrodes.ports[edge.portIndex].componentIndex == network.nodes[edge.nodeIndex].componentIndex else { throw .invalidNetwork }
            try emit(id: "native.contact.\(index)", kind: .resistor, a: electrodes.ports[edge.portIndex].terminal,
                     b: numericRefs[edge.nodeIndex], value: edge.ohms)
        }
        for (index, edge) in network.capacitors.enumerated() {
            guard numericRefs.indices.contains(edge.nodeA) else { throw .invalidNetwork }
            let b: NodeRef?
            if let other = edge.nodeB {
                guard numericRefs.indices.contains(other), other != edge.nodeA, edge.kind != .ground else { throw .invalidNetwork }
                b = numericRefs[other]
            } else { guard edge.kind == .ground else { throw .invalidNetwork }; b = nil }
            try emit(id: "native.c.\(index)", kind: b == nil ? .capacitor : .coupling,
                     a: numericRefs[edge.nodeA], b: b, value: edge.farads)
        }
        var nets: [ParasiticNet] = []
        var totalGround = 0.0, totalCoupling = 0.0, totalResistance = 0.0
        try budget.visit(isCancelled)
        for name in buckets.keys.sorted(by: { $0.value < $1.value }) {
            try budget.visit(isCancelled)
            let bucket = buckets[name]!
            guard bucket.ground.isFinite, bucket.coupling.isFinite, bucket.resistance.isFinite else { throw .numericFailure }
            totalGround += bucket.ground; totalCoupling += bucket.coupling; totalResistance += bucket.resistance
            guard totalGround.isFinite, totalCoupling.isFinite, totalResistance.isFinite else { throw .numericFailure }
            nets.append(.init(name: name, nodes: bucket.nodes, totalGroundCapF: bucket.ground,
                              totalCouplingCapF: bucket.coupling, totalResistanceOhm: bucket.resistance))
        }
        try budget.visit(isCancelled)
        let ir = ParasiticIR(version: ParasiticIR.currentVersion, cornerID: network.model.cornerID, units: .canonical,
            nets: nets, elements: elements, metadata: ["nativeLaw": network.model.law.rawValue,
                "referenceNodeName": network.model.referenceNodeName,
                "maximumCellSpanDatabaseUnits": String(network.maximumCellSpanDatabaseUnits),
                "netTotalSemantics": "nodeA-owned operator inventory; not effective terminal resistance"])
        return NativePEXProjection(ir: ir, electrodes: electrodes, netBindings: normalized, numericNodeReferences: numericRefs)
    }

    private func unique(_ base: String, used: inout Set<String>, budget: inout NativePEXProjectionBudget,
                        isCancelled: () -> Bool) throws(NativePEXProjectionError) -> String {
        var candidate = base, suffix = 0
        while true {
            try budget.visit(isCancelled)
            if used.insert(candidate).inserted { return candidate }
            let (next, overflow) = suffix.addingReportingOverflow(1)
            guard !overflow else { throw .numericFailure }
            suffix = next; candidate = "\(base)_\(suffix)"
        }
    }
}
