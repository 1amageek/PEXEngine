import Foundation
import Testing
import PEXCore
import LayoutCore
import LayoutVerify
@testable import PEXNative

@Suite("Exact native canonical projection", .timeLimit(.minutes(1)))
struct NativePEXProjectionTests {
    private let fixture = NativePEXTestFixture()
    private func terminal(_ net: String, _ node: String = "P") -> NodeRef {
        .init(netName: NetName(net), nodeName: NodeName(node))
    }
    private func square(_ x: Double, net: UUID? = nil) -> LayoutShape {
        var shape = fixture.rect(x, 0, 1, 1); shape.netID = net; return shape
    }
    private func pin(_ x: Double, net: UUID? = nil, name: String = "P") -> LayoutPin {
        .init(name: name, position: .init(x: x + 0.5, y: 0.5), size: .init(width: 1, height: 1), layer: fixture.m1, netID: net)
    }
    private func network(_ cell: LayoutCell, children: [LayoutCell] = []) throws -> NativePEXNetwork {
        try RectilinearPEXCalculator().calculate(snapshot: fixture.snapshot(cell, children: children), technology: fixture.technology(),
            corner: PEXCorner(id: "tt"), layerNames: fixture.bindings, maximumCellSpanDatabaseUnits: 500)
    }
    private func electrodes(_ network: NativePEXNetwork, terminals: [NodeRef], faces: [[NativePEXElectrodeFace]]? = nil)
        throws -> NativePEXElectrodeNetwork {
        try #require(terminals.count == network.snapshot.pins.count)
        let bindings = try terminals.enumerated().map { index, terminal in
            let selected: [NativePEXElectrodeFace]
            if let faces { selected = faces[index] }
            else if network.snapshot.pins[index].componentIndices.isEmpty { selected = [] }
            else {
                let band = try #require(network.snapshot.pins[index].bands.first)
                selected = [.init(side: .minX, coordinate: band.minX, begin: band.minY, end: band.maxY)]
            }
            return NativePEXElectrodeBinding(pinIndex: index, terminal: terminal, faces: selected)
        }
        return try RectilinearPEXElectrodeBuilder().build(network: network, bindings: bindings)
    }
    private func netBindings(_ network: NativePEXNetwork, name: (LayoutConductorSnapshot.NetReference) -> String) -> [NativePEXNetBinding] {
        let refs = Set(network.snapshot.components.flatMap(\.declaredNets) + network.snapshot.pins.compactMap(\.declaredNet))
        return refs.sorted { $0.occurrenceIndex == $1.occurrenceIndex ? $0.netID.uuidString < $1.netID.uuidString : $0.occurrenceIndex < $1.occurrenceIndex }
            .map { .init(reference: $0, netName: NetName(name($0))) }
    }
    private func project(_ graph: NativePEXElectrodeNetwork, _ bindings: [NativePEXNetBinding], limits: NativePEXProjectionLimits = .default)
        throws -> NativePEXProjection {
        let projector: any NativePEXProjecting = CanonicalPEXProjector()
        return try projector.project(electrodes: graph, netBindings: bindings, limits: limits, isCancelled: { Task.isCancelled })
    }

    @Test func everyOperatorAndCoordinateIsPreservedInCanonicalUnits() throws {
        let id = UUID(), source = try network(LayoutCell(name: "RC", shapes: [square(0, net: id)], pins: [pin(0, net: id)]))
        let graph = try electrodes(source, terminals: [terminal("SIGNAL")])
        let result = try project(graph, netBindings(source) { _ in "SIGNAL" })
        try verifyOperators(result)
        #expect(result.ir.units == .canonical && result.ir.cornerID == source.model.cornerID)
        #expect(result.ir.metadata["referenceNodeName"] == source.model.referenceNodeName)
        let first = try #require(result.ir.nets.flatMap(\.nodes).first { $0.name == result.numericNodeReferences[0].nodeName })
        #expect(abs(try #require(first.coordinate).x - 0.25) < 1e-15)
        #expect(abs(try #require(first.coordinate).y - 0.25) < 1e-15)
        #expect(ParasiticIRValidator().validate(result.ir).isValid)
        let encoded = try JSONEncoder().encode(result.ir)
        #expect(try JSONDecoder().decode(ParasiticIR.self, from: encoded) == result.ir)
        #expect(try JSONDecoder().decode([NativePEXNetBinding].self, from: JSONEncoder().encode(result.netBindings)) == result.netBindings)
        #expect(inventoryEqual(result.ir.nets.reduce(0) { $0 + $1.totalResistanceOhm },
            source.resistors.reduce(0) { $0 + $1.ohms } + graph.contacts.reduce(0) { $0 + $1.ohms },
            terms: source.resistors.count + graph.contacts.count))
    }

    @Test func sameNetIslandsDoNotAcquireAResistiveConnection() throws {
        let id = UUID(), source = try network(LayoutCell(name: "OPEN", shapes: [square(0, net: id), square(3, net: id)],
            pins: [pin(0, net: id, name: "A"), pin(3, net: id, name: "B")]))
        let a = terminal("SIGNAL", "A"), b = terminal("SIGNAL", "B")
        let result = try project(electrodes(source, terminals: [a, b]), netBindings(source) { _ in "SIGNAL" })
        #expect(result.ir.nets.count == 1 && result.electrodes.network.snapshot.opens.count == 1)
        #expect(!connected(a, b, ir: result.ir))
        #expect(result.ir.elements.contains { $0.kind == .coupling })
        try verifyOperators(result)
    }

    @Test func repeatedLeafNamesRemainExactOccurrenceScopedPorts() throws {
        let id = UUID(), child = LayoutCell(name: "CHILD", shapes: [square(0, net: id)], pins: [pin(0, net: id)])
        let top = LayoutCell(name: "TOP", instances: [LayoutInstance(cellID: child.id, name: "U0"),
            LayoutInstance(cellID: child.id, name: "U1", transform: .init(translation: .init(x: 3, y: 0)))])
        let source = try network(top, children: [child])
        let bindings = netBindings(source) { "U\($0.occurrenceIndex)/SIGNAL" }
        #expect(bindings.count == 2 && Set(bindings.map(\.netID)).count == 1 && Set(bindings.map(\.occurrenceIndex)).count == 2)
        let ports = source.snapshot.pins.map { terminal("U\($0.declaredNet!.occurrenceIndex)/SIGNAL") }
        let result = try project(electrodes(source, terminals: ports), bindings)
        #expect(ports[0].nodeName == ports[1].nodeName && ports[0].netName != ports[1].netName)
        #expect(!connected(ports[0], ports[1], ir: result.ir))
        #expect(result.ir.nets.flatMap(\.nodes).filter { $0.kind == .pin }.count == 2)
        #expect(result.electrodes.network.snapshot.hierarchy.occurrences == source.snapshot.hierarchy.occurrences)
        try verifyOperators(result)
    }

    @Test func physicalShortDoesNotSelectOneLogicalClaimant() throws {
        let a = UUID(), b = UUID()
        var first = fixture.rect(0, 0, 3, 1); first.netID = a
        let source = try network(LayoutCell(name: "SHORT", shapes: [first, square(2, net: b)],
            pins: [pin(0, net: a), pin(2, net: b)]))
        let ports = [terminal("A"), terminal("B")]
        let graph = try electrodes(source, terminals: ports, faces: [
            [.init(side: .minX, coordinate: 0, begin: 0, end: 1000)],
            [.init(side: .maxX, coordinate: 3000, begin: 0, end: 1000)]])
        let result = try project(graph, netBindings(source) { $0.netID == a ? "A" : "B" })
        #expect(source.snapshot.shortComponentIndices == [0] && result.electrodes.network.snapshot.shortComponentIndices == [0])
        #expect(Set(result.numericNodeReferences.map(\.netName)).count == 1)
        #expect(result.numericNodeReferences.allSatisfy { $0.netName != ports[0].netName && $0.netName != ports[1].netName })
        #expect(connected(ports[0], ports[1], ir: result.ir))
        #expect(result.ir.elements.filter { $0.id.hasPrefix("native.contact.") }.allSatisfy { $0.nodeA.netName != $0.nodeB?.netName })
        try verifyOperators(result)
    }

    @Test func floatingComponentsAndCrossNetCapacitanceRemainPresentOnce() throws {
        let id = UUID(), source = try network(LayoutCell(name: "FLOAT", shapes: [square(0, net: id), square(3)]))
        let result = try project(electrodes(source, terminals: []), netBindings(source) { _ in "SIGNAL" })
        let coupling = result.ir.elements.filter { $0.kind == .coupling }
        #expect(coupling.contains { $0.nodeA.netName != $0.nodeB?.netName })
        #expect(Set(result.numericNodeReferences.map(\.netName)).count == 2 && result.ir.nets.count == 2)
        #expect(inventoryEqual(result.ir.nets.reduce(0) { $0 + $1.totalCouplingCapF },
            source.capacitors.filter { $0.kind != .ground }.reduce(0) { $0 + $1.farads }, terms: source.capacitors.count))
        #expect(inventoryEqual(result.ir.nets.reduce(0) { $0 + $1.totalGroundCapF },
            source.capacitors.filter { $0.kind == .ground }.reduce(0) { $0 + $1.farads }, terms: source.capacitors.count))
        try verifyOperators(result)
        let unnamed = try network(LayoutCell(name: "UNNAMED", shapes: [square(0), square(3)]))
        let floating = try project(electrodes(unnamed, terminals: []), [])
        #expect(floating.ir.nets.count == 2 && floating.numericNodeReferences.count == unnamed.nodes.count)
        #expect(ParasiticIRValidator().validate(floating.ir).isValid)
    }

    @Test func individualCutAndInterlayerOperatorsSurviveProjection() throws {
        let a = UUID(), b = UUID()
        let lower = square(0, net: a)
        var upper = square(0, net: a); upper.layer = fixture.m2
        var cut = square(0, net: a); cut.layer = fixture.cut
        let connected = try network(LayoutCell(name: "CUT", shapes: [lower, upper, cut]))
        let cutResult = try project(electrodes(connected, terminals: []), netBindings(connected) { _ in "SIGNAL" })
        #expect(connected.nodes.contains { $0.kind == .cut(viaName: "VIA1") })
        #expect(connected.resistors.contains { $0.kind == .cut })
        try verifyOperators(cutResult)
        upper.netID = b
        let separated = try network(LayoutCell(name: "INTERLAYER", shapes: [lower, upper]))
        let fieldResult = try project(electrodes(separated, terminals: []), netBindings(separated) { $0.netID == a ? "LOWER" : "UPPER" })
        #expect(separated.capacitors.contains { $0.kind == .interlayer })
        #expect(fieldResult.ir.elements.filter { $0.kind == .coupling }.allSatisfy { $0.nodeA.netName != $0.nodeB?.netName })
        try verifyOperators(fieldResult)
    }

    @Test func uncontactedAndUndeclaredPinsKeepExplicitIsolatedIdentity() throws {
        let id = UUID(), source = try network(LayoutCell(name: "OPEN_PIN", shapes: [square(0)], pins: [pin(3, net: id), pin(6)]))
        let ports = [terminal("DECLARED"), terminal("UNDECLARED")]
        let result = try project(electrodes(source, terminals: ports), netBindings(source) { _ in "DECLARED" })
        #expect(result.electrodes.ports.allSatisfy { $0.componentIndex == nil })
        #expect(result.ir.nets.flatMap(\.nodes).filter { $0.kind == .pin }.count == 2)
        #expect(result.ir.elements.allSatisfy { !ports.contains($0.nodeA) && !($0.nodeB.map { ports.contains($0) } ?? false) })
        #expect(result.electrodes.network.snapshot.opens == source.snapshot.opens && source.snapshot.opens.count == 1)
        #expect(ParasiticIRValidator().validate(result.ir).isValid)
    }

    @Test func generatedNamesAvoidSourceCollisionsAndIgnoreBindingOrder() throws {
        let a = UUID(), b = UUID(), source = try network(LayoutCell(name: "COLLISION", shapes: [square(0, net: a), square(3, net: b), square(6)],
            pins: [pin(0, net: a), pin(3, net: b)]))
        let bindings = netBindings(source) { $0.netID == a ? "__PEX_COMPONENT_2" : "SECOND" }
        let ports = [terminal("__PEX_COMPONENT_2", "__PEX_NODE_0"), terminal("SECOND", "__PEX_NODE_0_1")]
        let graph = try electrodes(source, terminals: ports)
        let first = try project(graph, bindings), second = try project(graph, bindings.reversed())
        #expect(first.ir == second.ir && first.netBindings == second.netBindings && first.numericNodeReferences == second.numericNodeReferences)
        #expect(first.numericNodeReferences[0].nodeName.value == "__PEX_NODE_0_2")
        #expect(first.ir.nets.contains { $0.name.value == "__PEX_COMPONENT_2_1" })
        #expect(ParasiticIRValidator().validate(first.ir).isValid)
        try verifyOperators(first)
    }

    @Test func missingUnknownDuplicateAndAliasedNetBindingsFail() throws {
        let a = UUID(), b = UUID(), source = try network(LayoutCell(name: "BIND", shapes: [square(0, net: a), square(3, net: b)]))
        let graph = try electrodes(source, terminals: []), bindings = netBindings(source) { $0.netID == a ? "A" : "B" }
        let missing = bindings[1]
        #expect(throws: NativePEXProjectionError.missingBinding(occurrenceIndex: missing.occurrenceIndex, netID: missing.netID)) { try project(graph, [bindings[0]]) }
        let first = bindings[0]
        #expect(throws: NativePEXProjectionError.duplicateBinding(occurrenceIndex: first.occurrenceIndex, netID: first.netID)) { try project(graph, bindings + [first]) }
        let unknown = NativePEXNetBinding(occurrenceIndex: 100, netID: a, netName: NetName("UNKNOWN"))
        #expect(throws: NativePEXProjectionError.unknownBinding(occurrenceIndex: 100, netID: a)) { try project(graph, bindings + [unknown]) }
        #expect(throws: NativePEXProjectionError.duplicateNetName(first.netName.value)) {
            try project(graph, [first, .init(occurrenceIndex: missing.occurrenceIndex, netID: missing.netID, netName: first.netName)])
        }
        #expect(throws: NativePEXProjectionError.invalidIdentifier) {
            try project(graph, [.init(occurrenceIndex: first.occurrenceIndex, netID: first.netID, netName: NetName(" ")), missing])
        }
    }

    @Test func pinNetMustMatchItsExactCapturedReference() throws {
        let id = UUID(), source = try network(LayoutCell(name: "MISMATCH", shapes: [square(0, net: id)], pins: [pin(0, net: id)]))
        let graph = try electrodes(source, terminals: [terminal("INCORRECT")])
        #expect(throws: NativePEXProjectionError.terminalNetMismatch(pinIndex: 0)) { try project(graph, netBindings(source) { _ in "ACTUAL" }) }
    }

    @Test func limitsAndCancellationPublishNoPartialProjection() throws {
        let source = try network(LayoutCell(name: "BOUNDS", shapes: [square(0)])), graph = try electrodes(source, terminals: [])
        let projector = CanonicalPEXProjector()
        for (limits, error) in [(NativePEXProjectionLimits(maximumInputRecords: 0), NativePEXProjectionError.limitExceeded(.inputRecords)),
            (.init(maximumNodes: source.nodes.count - 1), .limitExceeded(.nodes)),
            (.init(maximumElements: source.resistors.count + source.capacitors.count - 1), .limitExceeded(.elements)),
            (.init(maximumWorkVisits: 0), .limitExceeded(.workVisits)), (.init(maximumNodes: -1), .invalidConfiguration)] {
            var output: NativePEXProjection?
            #expect(throws: error) { output = try project(graph, [], limits: limits) }
            #expect(output == nil)
        }
        var total = 0
        _ = try projector.project(electrodes: graph, netBindings: [], isCancelled: { total += 1; return false })
        for cancelAt in [1, total / 2, total - 1] {
            var checks = 0, output: NativePEXProjection?
            #expect(throws: NativePEXProjectionError.cancelled) {
                output = try projector.project(electrodes: graph, netBindings: [], isCancelled: { checks += 1; return checks == cancelAt })
            }
            #expect(checks == cancelAt && output == nil)
        }
        #expect(try project(graph, [], limits: .init(maximumNodes: source.nodes.count,
            maximumElements: source.resistors.count + source.capacitors.count)).numericNodeReferences.count == source.nodes.count)
    }

    @Test func oversizedNamesAndOverflowingInventoryAreExplicitFailures() throws {
        let id = UUID(), source = try network(LayoutCell(name: "FAILURE", shapes: [square(0, net: id)]))
        let graph = try electrodes(source, terminals: [])
        #expect(throws: NativePEXProjectionError.limitExceeded(.inputRecords)) {
            try project(graph, netBindings(source) { _ in String(repeating: "N", count: 1024) }, limits: .init(maximumInputRecords: 128))
        }
        // The projection owns aggregate representability even when individual operators are finite.
        let huge = NativePEXNetwork(snapshot: source.snapshot, model: source.model, metersPerDatabaseUnit: source.metersPerDatabaseUnit,
            maximumCellSpanDatabaseUnits: source.maximumCellSpanDatabaseUnits, nodes: source.nodes,
            resistors: source.resistors.map { .init(kind: $0.kind, nodeA: $0.nodeA, nodeB: $0.nodeB, ohms: Double.greatestFiniteMagnitude) },
            capacitors: source.capacitors, pinContacts: source.pinContacts)
        var output: NativePEXProjection?
        #expect(throws: NativePEXProjectionError.numericFailure) {
            output = try project(electrodes(huge, terminals: []), netBindings(huge) { _ in "HUGE" })
        }
        #expect(output == nil)
        for value in [0.0, -1, Double.nan, Double.infinity] {
            let invalid = NativePEXNetwork(snapshot: source.snapshot, model: source.model, metersPerDatabaseUnit: source.metersPerDatabaseUnit,
                maximumCellSpanDatabaseUnits: source.maximumCellSpanDatabaseUnits, nodes: source.nodes,
                resistors: source.resistors.map { .init(kind: $0.kind, nodeA: $0.nodeA, nodeB: $0.nodeB, ohms: value) },
                capacitors: source.capacitors, pinContacts: source.pinContacts)
            #expect(throws: NativePEXProjectionError.numericFailure) {
                output = try project(electrodes(invalid, terminals: []), netBindings(invalid) { _ in "INVALID" })
            }
            #expect(output == nil)
        }
    }

    @Test func individuallyFiniteNetInventoriesCannotOverflowTheWholeGraph() throws {
        let a = UUID(), b = UUID(), source = try network(LayoutCell(name: "GLOBAL_OVERFLOW", shapes: [square(0, net: a), square(3, net: b)]))
        var components: Set<Int> = []
        let capacitors = source.capacitors.filter { edge in
            edge.kind == .ground && components.insert(source.nodes[edge.nodeA].componentIndex).inserted
        }.map { NativePEXNetwork.Capacitor(kind: .ground, nodeA: $0.nodeA, nodeB: nil, farads: Double.greatestFiniteMagnitude) }
        try #require(capacitors.count == 2)
        let huge = NativePEXNetwork(snapshot: source.snapshot, model: source.model, metersPerDatabaseUnit: source.metersPerDatabaseUnit,
            maximumCellSpanDatabaseUnits: source.maximumCellSpanDatabaseUnits, nodes: source.nodes, resistors: source.resistors,
            capacitors: capacitors, pinContacts: source.pinContacts)
        var output: NativePEXProjection?
        #expect(throws: NativePEXProjectionError.numericFailure) {
            output = try project(electrodes(huge, terminals: []), netBindings(huge) { $0.netID == a ? "A" : "B" })
        }
        #expect(output == nil)
    }

    // Positive inventory regrouping changes rounding, never an individual operator's value.
    private func inventoryEqual(_ actual: Double, _ expected: Double, terms: Int) -> Bool {
        actual.isFinite && expected.isFinite && abs(actual - expected)
            <= Double(max(1, terms)) * Double.ulpOfOne * max(abs(actual), abs(expected)) * 2
    }

    private func verifyOperators(_ result: NativePEXProjection) throws {
        let source = result.electrodes.network, refs = result.numericNodeReferences
        #expect(refs.count == source.nodes.count && Set(refs).count == refs.count)
        #expect(result.ir.elements.count == source.resistors.count + result.electrodes.contacts.count + source.capacitors.count)
        try #require(Set(result.ir.elements.map(\.id)).count == result.ir.elements.count)
        let elements = Dictionary(uniqueKeysWithValues: result.ir.elements.map { ($0.id, $0) })
        for (index, edge) in source.resistors.enumerated() {
            let actual = try #require(elements["native.r.\(index)"])
            #expect(actual.kind == .resistor && actual.nodeA == refs[edge.nodeA] && actual.nodeB == refs[edge.nodeB] && actual.value == edge.ohms)
        }
        for (index, edge) in result.electrodes.contacts.enumerated() {
            let actual = try #require(elements["native.contact.\(index)"])
            #expect(actual.kind == .resistor && actual.nodeA == result.electrodes.ports[edge.portIndex].terminal && actual.nodeB == refs[edge.nodeIndex] && actual.value == edge.ohms)
        }
        for (index, edge) in source.capacitors.enumerated() {
            let actual = try #require(elements["native.c.\(index)"])
            #expect(actual.kind == (edge.kind == .ground ? .capacitor : .coupling) && actual.nodeA == refs[edge.nodeA]
                    && actual.nodeB == edge.nodeB.map { refs[$0] } && actual.value == edge.farads)
        }
        #expect(result.electrodes.network.snapshot == source.snapshot && ParasiticIRValidator().validate(result.ir).isValid)
    }

    // DC continuity follows resistors only; net membership and capacitors add no wires.
    private func connected(_ start: NodeRef, _ target: NodeRef, ir: ParasiticIR) -> Bool {
        var visited: Set<NodeRef> = [start], queue = [start], cursor = 0
        while cursor < queue.count {
            let node = queue[cursor]; cursor += 1
            if node == target { return true }
            for edge in ir.elements where edge.kind == .resistor {
                guard let b = edge.nodeB else { continue }
                let other: NodeRef?
                if edge.nodeA == node { other = b } else if b == node { other = edge.nodeA } else { other = nil }
                if let other, visited.insert(other).inserted { queue.append(other) }
            }
        }
        return false
    }
}
