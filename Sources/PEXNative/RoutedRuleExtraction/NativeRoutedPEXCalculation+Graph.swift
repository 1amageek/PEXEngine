import PEXCore

extension NativeRoutedPEXCalculation {
    mutating func graph(cornerID: PEXCornerID, isCancelled: () -> Bool) throws(NativeRoutedPEXError) -> NativeRoutedPEXResult {
        let g = geometry
        var budget = self.budget
        var positions = g.nodes, physical: [Geometry.PointKey: NodeRef] = [:]
        var samePoints: [Geometry.PointKey: [NodeRef]] = [:], equivalences: [(NodeRef, NodeRef)] = []
        var splits: [Int: Set<Int64>] = [:], nextNode = 0
        let admittedNodes = g.nodes.values.sorted {
            if $0.ref.netName != $1.ref.netName { return $0.ref.netName.value < $1.ref.netName.value }
            return $0.ref.nodeName.value < $1.ref.nodeName.value
        }
        for node in admittedNodes {
            try budget.visit(1, isCancelled); try budget.charge(.coordinateValues)
            samePoints[.init(net: node.ref.netName, layer: node.layerName, x: node.x, y: node.y), default: []].append(node.ref)
        }
        for node in admittedNodes {
            try budget.visit(1, isCancelled)
            let key = Geometry.PointKey(net: node.ref.netName, layer: node.layerName, x: node.x, y: node.y)
            if physical[key] != nil { continue }
            guard let refs = samePoints[key] else { throw .unrepresentableArithmetic }
            if refs.count == 1 { physical[key] = node.ref; continue }
            let junction: NodeRef
            if let existing = refs.first(where: { g.terminals[$0] == nil }) { junction = existing }
            else {
                var ref: NodeRef
                repeat {
                    try budget.visit(1, isCancelled)
                    ref = .init(netName: key.net, nodeName: .init("__native_rc_\(nextNode)")); nextNode += 1
                } while positions[ref] != nil
                try budget.charge(.graphNodes)
                positions[ref] = .init(ref: ref, layerName: key.layer, x: key.x, y: key.y, sourceFacts: node.sourceFacts)
                junction = ref
            }
            physical[key] = junction
            for ref in refs where ref != junction { equivalences.append((ref, junction)) }
        }
        func coordinate(_ wire: Input.Wire, _ node: Input.Node) -> Int64 { wire.axis == .horizontal ? node.x : node.y }
        func split(_ wire: Int, _ value: Int64) throws(NativeRoutedPEXError) {
            if splits[wire, default: []].insert(value).inserted { try budget.charge(.coordinateValues) }
        }
        func point(_ wire: Int, _ value: Int64) throws(NativeRoutedPEXError) -> NodeRef {
            let w = g.wires[wire]
            guard let a = positions[w.sourceNode] else { throw .invalidInput(reason: .node, sourceIDs: [w.sourceID]) }
            let x = w.axis == .horizontal ? value : a.x, y = w.axis == .horizontal ? a.y : value
            let key = Geometry.PointKey(net: w.netName, layer: w.layerName, x: x, y: y)
            if let ref = physical[key] { return ref }
            var ref: NodeRef
            repeat {
                try budget.visit(1, isCancelled)
                ref = .init(netName: w.netName, nodeName: .init("__native_rc_\(nextNode)")); nextNode += 1
            } while positions[ref] != nil
            try budget.charge(.graphNodes)
            positions[ref] = .init(ref: ref, layerName: w.layerName, x: x, y: y, sourceFacts: w.sourceFacts)
            physical[key] = ref
            return ref
        }
        for (index, w) in g.wires.enumerated() where g.roles[w.netName] == .signal {
            guard let a = g.nodes[w.sourceNode], let b = g.nodes[w.targetNode] else { throw .invalidInput(reason: .node, sourceIDs: [w.sourceID]) }
            try split(index, coordinate(w, a)); try split(index, coordinate(w, b))
            for node in g.nodes.values {
                try budget.visit(1, isCancelled)
                if node.ref.netName == w.netName && node.layerName == w.layerName && Geometry.onCenterline(w, node, g.nodes) {
                    try split(index, coordinate(w, node))
                }
            }
        }
        for i in g.wires.indices {
            for j in g.wires.indices where j > i {
                try budget.visit(1, isCancelled)
                let a = g.wires[i], b = g.wires[j]
                if a.layerName != b.layerName || !Geometry.conductiveContact(a.rect, b.rect) { continue }
                if a.netName != b.netName { throw .invalidInput(reason: .shortCircuit, sourceIDs: [a.sourceID, b.sourceID]) }
                if g.roles[a.netName] == .reference { continue }
                guard let aa = g.nodes[a.sourceNode], let ab = g.nodes[a.targetNode],
                      let ba = g.nodes[b.sourceNode], let bb = g.nodes[b.targetNode] else {
                    throw .invalidInput(reason: .node, sourceIDs: [a.sourceID, b.sourceID])
                }
                if a.axis == b.axis {
                    let normalA = a.axis == .horizontal ? aa.y : aa.x, normalB = b.axis == .horizontal ? ba.y : ba.x
                    let low = max(min(coordinate(a, aa), coordinate(a, ab)), min(coordinate(b, ba), coordinate(b, bb)))
                    let high = min(max(coordinate(a, aa), coordinate(a, ab)), max(coordinate(b, ba), coordinate(b, bb)))
                    if normalA == normalB && high > low { throw .invalidInput(reason: .duplicateWire, sourceIDs: [a.sourceID, b.sourceID]) }
                    guard normalA == normalB && high == low else {
                        throw .invalidInput(reason: .nonCenterlineContact, sourceIDs: [a.sourceID, b.sourceID])
                    }
                } else {
                    let horizontal = a.axis == .horizontal ? a : b, vertical = a.axis == .vertical ? a : b
                    guard let h = g.nodes[horizontal.sourceNode], let v = g.nodes[vertical.sourceNode] else {
                        throw .invalidInput(reason: .node, sourceIDs: [a.sourceID, b.sourceID])
                    }
                    let node = Input.Node(ref: h.ref, layerName: a.layerName, x: v.x, y: h.y, sourceFacts: a.sourceFacts)
                    guard Geometry.onCenterline(a, node, g.nodes), Geometry.onCenterline(b, node, g.nodes) else {
                        throw .invalidInput(reason: .nonCenterlineContact, sourceIDs: [a.sourceID, b.sourceID])
                    }
                    try split(i, coordinate(a, node)); try split(j, coordinate(b, node))
                    _ = try point(i, coordinate(a, node))
                }
            }
        }
        for via in g.vias {
            for landing in via.landings {
                for (index, wire) in g.wires.enumerated() {
                    try budget.visit(1, isCancelled)
                    if wire.layerName != landing.layerName || !Geometry.conductiveContact(wire.rect, landing.rect) { continue }
                    if wire.netName != via.netName { throw .invalidInput(reason: .shortCircuit, sourceIDs: [wire.sourceID, via.sourceID]) }
                    if g.roles[wire.netName] == .reference { continue }
                    guard let a = g.nodes[via.sourceNode], let b = g.nodes[via.targetNode] else {
                        throw .invalidInput(reason: .via, sourceIDs: [via.sourceID])
                    }
                    let node = a.layerName == wire.layerName ? a : b
                    guard Geometry.onCenterline(wire, node, g.nodes) else {
                        throw .invalidInput(reason: .nonCenterlineContact, sourceIDs: [wire.sourceID, via.sourceID])
                    }
                    try split(index, coordinate(wire, node))
                }
            }
        }
        for i in g.vias.indices {
            for j in g.vias.indices where j > i {
                if g.vias[i].netName == g.vias[j].netName { continue }
                for a in g.vias[i].landings { for b in g.vias[j].landings {
                    try budget.visit(1, isCancelled)
                    if a.layerName == b.layerName && Geometry.conductiveContact(a.rect, b.rect) {
                        throw .invalidInput(reason: .shortCircuit, sourceIDs: [g.vias[i].sourceID, g.vias[j].sourceID])
                    }
                } }
            }
        }
        func clamped(_ wire: Int, _ value: Int64) throws(NativeRoutedPEXError) -> Int64 {
            let w = g.wires[wire]
            guard let a = g.nodes[w.sourceNode], let b = g.nodes[w.targetNode] else { throw .invalidInput(reason: .node, sourceIDs: [w.sourceID]) }
            return min(max(value, min(coordinate(w, a), coordinate(w, b))), max(coordinate(w, a), coordinate(w, b)))
        }
        for cap in caps {
            try budget.visit(1, isCancelled)
            for wire in [cap.a] + (cap.b.map { [$0] } ?? []) {
                try split(wire, clamped(wire, cap.span.low)); try split(wire, clamped(wire, cap.span.high))
            }
        }
        var elements: [ParasiticElement] = [], used = Set<NodeRef>(), generated = Set(positions.keys).subtracting(g.nodes.keys)
        func use(_ ref: NodeRef) throws(NativeRoutedPEXError) {
            guard positions[ref] != nil else { throw .invalidInput(reason: .node, sourceIDs: [ref.nodeName.value]) }
            if used.insert(ref).inserted && !generated.contains(ref) { try budget.charge(.graphNodes) }
        }
        func emit(_ kind: ElementKind, _ a: NodeRef, _ b: NodeRef?, _ value: Double,
                  samePointEquivalence: Bool = false) throws(NativeRoutedPEXError) {
            try budget.visit(1, isCancelled)
            guard value.isFinite, value > 0 || (samePointEquivalence && kind == .resistor && value == 0 && b != nil) else {
                throw .unrepresentableArithmetic
            }
            try use(a); if let b { try use(b) }
            try budget.charge(.graphElements)
            elements.append(.init(id: "native.routed.\(elements.count)", kind: kind, nodeA: a, nodeB: b, value: value, source: .extracted))
        }
        for (terminal, junction) in equivalences {
            try emit(.resistor, terminal, junction, 0, samePointEquivalence: true)
        }
        let resistance = PinnedRoutedLEFResistanceEvaluator()
        for (index, wire) in g.wires.enumerated() where g.roles[wire.netName] == .signal {
            guard let layer = g.layers[wire.layerName], let points = splits[index]?.sorted(), points.count >= 2 else {
                throw .invalidInput(reason: .wire, sourceIDs: [wire.sourceID])
            }
            let dx = wire.rect.maxX - wire.rect.minX, dy = wire.rect.maxY - wire.rect.minY
            let total: Double
            do { total = try resistance.wire(sheetResistanceOhmsPerSquare: layer.sheetResistanceOhmsPerSquare,
                    lengthDatabaseUnits: max(dx, dy), widthDatabaseUnits: min(dx, dy)) }
            catch { throw .sourceModel(error) }
            let complete = points[points.count - 1] - points[0]
            guard complete > 0 else { throw .invalidInput(reason: .wire, sourceIDs: [wire.sourceID]) }
            var sum = 0.0
            for i in 1..<points.count {
                try budget.visit(1, isCancelled)
                let value = i == points.count - 1 ? total - sum : total * (Double(points[i] - points[i - 1]) / Double(complete))
                let a = try point(index, points[i - 1]), b = try point(index, points[i])
                if g.nodes[a] == nil { generated.insert(a) }; if g.nodes[b] == nil { generated.insert(b) }
                try emit(.resistor, a, b, value); sum += value
            }
        }
        for via in g.vias where g.roles[via.netName] == .signal {
            try budget.visit(via.cuts.count, isCancelled)
            let value: Double
            do { value = try resistance.via(cutResistanceOhms: via.cuts.map(\.resistanceOhms),
                maximumCuts: budget.limits.maximumInputRecords, isCancelled: isCancelled) }
            catch { if error == .cancelled { throw .cancelled }; throw .sourceModel(error) }
            try emit(.resistor, via.sourceNode, via.targetNode, value)
        }
        for cap in caps {
            let al = try point(cap.a, clamped(cap.a, cap.span.low)), ah = try point(cap.a, clamped(cap.a, cap.span.high))
            if g.nodes[al] == nil { generated.insert(al) }; if g.nodes[ah] == nil { generated.insert(ah) }
            let bl = try cap.b.map { (wire: Int) throws(NativeRoutedPEXError) -> NodeRef in try point(wire, clamped(wire, cap.span.low)) }
            let bh = try cap.b.map { (wire: Int) throws(NativeRoutedPEXError) -> NodeRef in try point(wire, clamped(wire, cap.span.high)) }
            if let bl, g.nodes[bl] == nil { generated.insert(bl) }; if let bh, g.nodes[bh] == nil { generated.insert(bh) }
            if al == ah && bl == bh { try emit(cap.b == nil ? .capacitor : .coupling, al, bl, cap.farads) }
            else {
                try emit(cap.b == nil ? .capacitor : .coupling, al, bl, cap.farads / 2)
                try emit(cap.b == nil ? .capacitor : .coupling, ah, bh, cap.farads / 2)
            }
        }
        for cap in viaCaps where cap.farads > 0 { try emit(.capacitor, cap.node, nil, cap.farads) }
        var adjacency: [NodeRef: [NodeRef]] = [:]
        for e in elements where e.kind == .resistor {
            guard let b = e.nodeB else { throw .unrepresentableArithmetic }
            adjacency[e.nodeA, default: []].append(b); adjacency[b, default: []].append(e.nodeA)
        }
        var nets: [ParasiticNet] = []
        for net in g.input.nets.sorted(by: { $0.name.value < $1.name.value }) where net.role == .signal {
            let members = used.filter { $0.netName == net.name }.sorted { $0.nodeName.value < $1.nodeName.value }
            guard let first = members.first, g.terminals.keys.contains(where: { $0.netName == net.name }) else { throw .disconnectedNet(net.name) }
            var queue = [first], visited = Set([first]), cursor = 0
            while cursor < queue.count {
                try budget.visit(1, isCancelled)
                for next in adjacency[queue[cursor]] ?? [] {
                    try budget.visit(1, isCancelled)
                    if visited.insert(next).inserted { queue.append(next) }
                }
                cursor += 1
            }
            guard members.allSatisfy({ visited.contains($0) }),
                  g.nodes.keys.filter({ $0.netName == net.name }).allSatisfy({ used.contains($0) }),
                  g.terminals.keys.filter({ $0.netName == net.name }).allSatisfy({ used.contains($0) }) else { throw .disconnectedNet(net.name) }
            var ground = 0.0, coupling = 0.0, r = 0.0
            for e in elements {
                try budget.visit(1, isCancelled)
                if e.kind == .resistor && e.nodeA.netName == net.name { r += e.value }
                if e.kind == .capacitor && e.nodeA.netName == net.name { ground += e.value }
                if e.kind == .coupling && (e.nodeA.netName == net.name || e.nodeB?.netName == net.name) { coupling += e.value }
            }
            guard ground.isFinite, coupling.isFinite, r.isFinite else { throw .unrepresentableArithmetic }
            var canonical: [ParasiticNode] = []
            for ref in members {
                guard let node = positions[ref] else { throw .invalidInput(reason: .node, sourceIDs: [ref.nodeName.value]) }
                canonical.append(.init(name: ref.nodeName, kind: g.terminals[ref] == nil ? .internal : .pin,
                    instancePath: g.terminals[ref]?.instancePath,
                    coordinate: .init(x: Double(node.x) / Double(g.input.databaseUnitsPerMicron),
                                      y: Double(node.y) / Double(g.input.databaseUnitsPerMicron))))
            }
            nets.append(.init(name: net.name, nodes: canonical, totalGroundCapF: ground, totalCouplingCapF: coupling, totalResistanceOhm: r))
        }
        self.budget = budget
        return .init(ir: .init(version: ParasiticIR.currentVersion, cornerID: cornerID, units: .canonical, nets: nets, elements: elements,
            metadata: ["native.routed.profile": g.profile.rawValue, "native.routed.discretization": "source-bbox-resistance-centerline-pi-v1",
                "native.routed.rcCorner": g.input.selection.corner.rawValue, "native.routed.rulesSHA256": g.input.selection.rulesArtifactID.digest.hexadecimalValue,
                "native.routed.pinCapacitance": "excluded", "native.routed.referenceDiagonalEmission": "signal-ground-correction"]),
            selection: g.input.selection, sourceFacts: g.sourceFacts, queryReceipts: queryReceipts,
            viaLandingReceipts: viaLandingReceipts, workVisitsConsumed: budget.workVisitsConsumed)
    }
}
