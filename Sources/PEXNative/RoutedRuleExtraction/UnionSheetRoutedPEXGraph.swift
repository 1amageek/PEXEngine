import PEXCore

/// Canonical graph composition of an admitted union-sheet numerical network.
struct UnionSheetRoutedPEXGraph {
    let nodeRefs: [Int: NodeRef]
    var elements: [ParasiticElement]
    let resistanceContributors: [String: [Int]]
    let resistanceCutSourceIDs: [String: String]
    private let signalNames: [NetName]
    private let canonicalNodes: [NodeRef: ParasiticNode]
    private let members: [NetName: [NodeRef]]
    private let terminalRefs: [NetName: Set<NodeRef>]

    init(sheet: NativeSheetResistanceResult, input: NativeRoutedPEXInput,
         budget: inout NativeRoutedPEXWorkBudget, isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        try budget.visit(1, isCancelled)
        guard input.databaseUnitsPerMicron > 0 else { throw .invalidInput(reason: .units, sourceIDs: []) }
        var roles: [NetName: NativeRoutedPEXInput.Role] = [:]
        try budget.charge(.inputRecords, input.nets.count)
        for net in input.nets {
            try Self.identifier(net.name.value, budget: &budget, isCancelled: isCancelled)
            guard roles.updateValue(net.role, forKey: net.name) == nil else { throw .invalidInput(reason: .net, sourceIDs: []) }
        }
        try Self.sorting(input.nets.count, budget: &budget, isCancelled: isCancelled)
        let signals = input.nets.filter { $0.role == .signal }.map(\.name).sorted { $0.value < $1.value }
        var original: [NodeRef: NativeRoutedPEXInput.Node] = [:]
        var occupiedRefs = Set<NodeRef>()
        try budget.charge(.inputRecords, input.nodes.count)
        for node in input.nodes {
            try budget.visit(1, isCancelled)
            try Self.admitRef(node.ref, budget: &budget, isCancelled: isCancelled)
            guard roles[node.ref.netName] != nil, original.updateValue(node, forKey: node.ref) == nil else {
                throw .invalidInput(reason: .node, sourceIDs: [node.ref.nodeName.value])
            }
            occupiedRefs.insert(node.ref)
        }
        var terminals: [NodeRef: NativeRoutedPEXInput.Terminal] = [:]
        try budget.charge(.inputRecords, input.terminals.count)
        for terminal in input.terminals {
            try budget.visit(1, isCancelled)
            try Self.admitRef(terminal.ref, budget: &budget, isCancelled: isCancelled)
            guard roles[terminal.ref.netName] != nil, original[terminal.ref] != nil,
                  terminals.updateValue(terminal, forKey: terminal.ref) == nil else {
                throw .invalidInput(reason: .terminal, sourceIDs: [terminal.ref.nodeName.value])
            }
            occupiedRefs.insert(terminal.ref)
        }
        var firstCells: [Int: NativeSheetResistanceResult.Cell] = [:]
        try budget.charge(.inputRecords, sheet.cells.count)
        for cell in sheet.cells {
            try budget.visit(1, isCancelled)
            guard sheet.nodes.indices.contains(cell.nodeIndex), sheet.nodes[cell.nodeIndex].netName == cell.netName else {
                throw .invalidInput(reason: .node, sourceIDs: [])
            }
            if firstCells[cell.nodeIndex] == nil { firstCells[cell.nodeIndex] = cell }
        }
        var cuts: [String: NativeSheetResistanceInput.Cut] = [:]
        try budget.charge(.inputRecords, sheet.input.cuts.count)
        for cut in sheet.input.cuts {
            try budget.visit(1, isCancelled)
            try Self.identifier(cut.sourceID, budget: &budget, isCancelled: isCancelled)
            guard cuts.updateValue(cut, forKey: cut.sourceID) == nil else { throw .invalidInput(reason: .via, sourceIDs: [cut.sourceID]) }
        }
        var refs: [Int: NodeRef] = [:], nodes: [NodeRef: ParasiticNode] = [:]
        var grouped: [NetName: [NodeRef]] = [:]
        var nextName = 0
        try budget.charge(.inputRecords, sheet.nodes.count)
        for (index, node) in sheet.nodes.enumerated() {
            try budget.visit(1, isCancelled)
            guard let role = roles[node.netName] else { throw .invalidInput(reason: .net, sourceIDs: []) }
            guard role == .signal else { continue }
            let rect: NativeConductorUnion.Rect
            switch node.kind {
            case .cut(let sourceID):
                guard let cut = cuts[sourceID], cut.netName == node.netName else { throw .invalidInput(reason: .via, sourceIDs: [sourceID]) }
                rect = cut.rect
            case .contact, .sheet:
                guard let cell = firstCells[index] else { throw .invalidInput(reason: .node, sourceIDs: []) }
                rect = cell.rect
            }
            var ref: NodeRef
            repeat {
                try budget.visit(1, isCancelled)
                let name = try Self.generatedID(prefix: "__native_union_rc_", index: nextName, budget: &budget)
                let (next, overflow) = nextName.addingReportingOverflow(1)
                guard !overflow else { throw .unrepresentableArithmetic }; nextName = next
                ref = .init(netName: node.netName, nodeName: .init(name))
            } while occupiedRefs.contains(ref)
            try budget.charge(.graphNodes)
            try budget.charge(.inputRecords, 3)
            let scale = Double(input.databaseUnitsPerMicron)
            let x = (Double(rect.minX) + Double(rect.maxX)) / (2 * scale)
            let y = (Double(rect.minY) + Double(rect.maxY)) / (2 * scale)
            guard x.isFinite, y.isFinite else { throw .unrepresentableArithmetic }
            occupiedRefs.insert(ref); refs[index] = ref
            nodes[ref] = .init(name: ref.nodeName, kind: .internal, instancePath: nil, coordinate: .init(x: x, y: y))
            grouped[ref.netName, default: []].append(ref)
        }
        var output: [ParasiticElement] = [], contributors: [String: [Int]] = [:], cutIDs: [String: String] = [:]
        for resistor in sheet.resistors {
            try budget.visit(1, isCancelled)
            guard sheet.nodes.indices.contains(resistor.nodeA), sheet.nodes.indices.contains(resistor.nodeB) else {
                throw .invalidInput(reason: .node, sourceIDs: [])
            }
            let aNode = sheet.nodes[resistor.nodeA], bNode = sheet.nodes[resistor.nodeB]
            guard aNode.netName == bNode.netName, let role = roles[aNode.netName] else {
                throw .invalidInput(reason: .shortCircuit, sourceIDs: [])
            }
            guard role == .signal else { continue }
            guard let a = refs[resistor.nodeA], let b = refs[resistor.nodeB], a != b,
                  resistor.ohms.isFinite, resistor.ohms > 0 else { throw .unrepresentableArithmetic }
            try budget.charge(.graphElements)
            let id = try Self.generatedID(prefix: "native.routed.union.", index: output.count, budget: &budget)
            try budget.charge(.inputRecords)
            try budget.charge(.inputRecords, resistor.contributorIndices.count)
            for index in resistor.contributorIndices {
                try budget.visit(1, isCancelled)
                guard sheet.conductorUnion.sources.indices.contains(index) else { throw .invalidInput(reason: .sourceIdentity, sourceIDs: []) }
            }
            contributors[id] = resistor.contributorIndices
            if case .cut(let sourceID) = resistor.kind {
                try Self.identifier(sourceID, budget: &budget, isCancelled: isCancelled)
                try budget.charge(.inputRecords); cutIDs[id] = sourceID
            }
            output.append(.init(id: id, kind: .resistor, nodeA: a, nodeB: b, value: resistor.ohms, source: .extracted))
        }
        var pins: [NetName: Set<NodeRef>] = [:], assignments = Set<NodeRef>()
        try budget.charge(.inputRecords, sheet.terminalAssignments.count)
        for assignment in sheet.terminalAssignments {
            try budget.visit(1, isCancelled)
            try Self.admitRef(assignment.ref, budget: &budget, isCancelled: isCancelled)
            guard let role = roles[assignment.ref.netName], sheet.nodes.indices.contains(assignment.nodeIndex),
                  sheet.nodes[assignment.nodeIndex].netName == assignment.ref.netName,
                  assignments.insert(assignment.ref).inserted else { throw .invalidInput(reason: .terminal, sourceIDs: []) }
            guard role == .signal else { continue }
            guard let terminal = terminals[assignment.ref], let originalNode = original[assignment.ref],
                  let junction = refs[assignment.nodeIndex] else { throw .invalidInput(reason: .terminal, sourceIDs: [assignment.ref.nodeName.value]) }
            try budget.charge(.graphNodes)
            try budget.charge(.inputRecords, 3)
            let x = Double(originalNode.x) / Double(input.databaseUnitsPerMicron)
            let y = Double(originalNode.y) / Double(input.databaseUnitsPerMicron)
            guard x.isFinite, y.isFinite else { throw .unrepresentableArithmetic }
            nodes[assignment.ref] = .init(name: assignment.ref.nodeName, kind: .pin, instancePath: terminal.instancePath,
                                         coordinate: .init(x: x, y: y))
            grouped[assignment.ref.netName, default: []].append(assignment.ref)
            pins[assignment.ref.netName, default: []].insert(assignment.ref)
            try budget.charge(.graphElements)
            let id = try Self.generatedID(prefix: "native.routed.union.", index: output.count, budget: &budget)
            // This alias encodes the admitted contact-area Dirichlet condition, not a wire resistance.
            output.append(.init(id: id, kind: .resistor, nodeA: assignment.ref, nodeB: junction, value: 0, source: .extracted))
        }
        for terminal in input.terminals {
            try budget.visit(1, isCancelled)
            if roles[terminal.ref.netName] == .signal, !assignments.contains(terminal.ref) {
                throw .disconnectedNet(terminal.ref.netName)
            }
        }
        self.nodeRefs = refs; self.elements = output; self.resistanceContributors = contributors
        self.resistanceCutSourceIDs = cutIDs; self.signalNames = signals; self.canonicalNodes = nodes
        self.members = grouped; self.terminalRefs = pins
    }

    mutating func appendCapacitance(a: Int, b: Int?, farads: Double,
                                    budget: inout NativeRoutedPEXWorkBudget, isCancelled: () -> Bool)
        throws(NativeRoutedPEXError) -> String {
        try budget.visit(1, isCancelled)
        guard farads.isFinite, farads > 0, let first = nodeRefs[a] else { throw .unrepresentableArithmetic }
        var second: NodeRef?
        if let b {
            guard let other = nodeRefs[b], first.netName != other.netName else { throw .invalidInput(reason: .net, sourceIDs: []) }
            second = other
        }
        try budget.charge(.graphElements)
        let id = try Self.generatedID(prefix: "native.routed.union.", index: elements.count, budget: &budget)
        elements.append(.init(id: id, kind: b == nil ? .capacitor : .coupling, nodeA: first, nodeB: second,
                              value: farads, source: .extracted))
        return id
    }

    func finish(cornerID: PEXCornerID, metadata: [String: String], budget: inout NativeRoutedPEXWorkBudget,
                isCancelled: () -> Bool) throws(NativeRoutedPEXError) -> ParasiticIR {
        try budget.visit(1, isCancelled)
        try Self.identifier(cornerID.value, budget: &budget, isCancelled: isCancelled)
        try budget.charge(.inputRecords, metadata.count)
        for (key, value) in metadata {
            for string in [key, value] {
                for _ in string.utf8 { try budget.visit(1, isCancelled); try budget.charge(.stringBytes) }
            }
        }
        var adjacency: [NodeRef: [NodeRef]] = [:]
        var resistance: [NetName: Double] = [:], ground: [NetName: Double] = [:], coupling: [NetName: Double] = [:]
        for element in elements {
            try budget.visit(1, isCancelled)
            guard canonicalNodes[element.nodeA] != nil, element.value.isFinite, element.value >= 0,
                  element.nodeB == nil || canonicalNodes[element.nodeB!] != nil else { throw .unrepresentableArithmetic }
            switch element.kind {
            case .resistor:
                guard let b = element.nodeB, b.netName == element.nodeA.netName else { throw .unrepresentableArithmetic }
                try budget.charge(.inputRecords, 2)
                adjacency[element.nodeA, default: []].append(b); adjacency[b, default: []].append(element.nodeA)
                resistance[element.nodeA.netName, default: 0] += element.value
            case .capacitor:
                guard element.nodeB == nil, element.value > 0 else { throw .unrepresentableArithmetic }
                ground[element.nodeA.netName, default: 0] += element.value
            case .coupling:
                guard let b = element.nodeB, b.netName != element.nodeA.netName, element.value > 0 else { throw .unrepresentableArithmetic }
                coupling[element.nodeA.netName, default: 0] += element.value
                coupling[b.netName, default: 0] += element.value
            case .inductor:
                throw .unrepresentableArithmetic
            }
        }
        var nets: [ParasiticNet] = []
        for name in signalNames {
            try budget.visit(1, isCancelled)
            guard let members = members[name], let first = members.first, let pins = terminalRefs[name], !pins.isEmpty else {
                throw .disconnectedNet(name)
            }
            try budget.charge(.inputRecords)
            var visited = Set([first]), queue = [first], cursor = 0
            while cursor < queue.count {
                try budget.visit(1, isCancelled)
                let ref = queue[cursor]; cursor += 1
                for next in adjacency[ref] ?? [] {
                    try budget.visit(1, isCancelled)
                    guard next.netName == name else { throw .invalidInput(reason: .shortCircuit, sourceIDs: []) }
                    if !visited.contains(next) { try budget.charge(.inputRecords); visited.insert(next); queue.append(next) }
                }
            }
            for ref in members { try budget.visit(1, isCancelled); guard visited.contains(ref) else { throw .disconnectedNet(name) } }
            for ref in pins { try budget.visit(1, isCancelled); guard visited.contains(ref) else { throw .disconnectedNet(name) } }
            let r = resistance[name] ?? 0, cg = ground[name] ?? 0, cc = coupling[name] ?? 0
            guard r.isFinite, cg.isFinite, cc.isFinite else { throw .unrepresentableArithmetic }
            try Self.sorting(members.count, budget: &budget, isCancelled: isCancelled)
            let ordered = members.sorted { $0.nodeName.value < $1.nodeName.value }
            try budget.charge(.inputRecords, ordered.count)
            var canonical: [ParasiticNode] = []
            for ref in ordered {
                try budget.visit(1, isCancelled)
                guard let node = canonicalNodes[ref] else { throw .invalidInput(reason: .node, sourceIDs: []) }
                canonical.append(node)
            }
            try budget.charge(.inputRecords)
            nets.append(.init(name: name, nodes: canonical, totalGroundCapF: cg, totalCouplingCapF: cc, totalResistanceOhm: r))
        }
        return .init(version: ParasiticIR.currentVersion, cornerID: cornerID, units: .canonical,
                     nets: nets, elements: elements, metadata: metadata)
    }

    private static func admitRef(_ ref: NodeRef, budget: inout NativeRoutedPEXWorkBudget,
                                 isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        try identifier(ref.netName.value, budget: &budget, isCancelled: isCancelled)
        try identifier(ref.nodeName.value, budget: &budget, isCancelled: isCancelled)
    }
    private static func identifier(_ value: String, budget: inout NativeRoutedPEXWorkBudget,
                                   isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        for _ in value.utf8 { try budget.visit(1, isCancelled); try budget.charge(.stringBytes) }
        guard !value.isEmpty else { throw .invalidInput(reason: .sourceIdentity, sourceIDs: []) }
    }
    private static func generatedID(prefix: String, index: Int, budget: inout NativeRoutedPEXWorkBudget)
        throws(NativeRoutedPEXError) -> String {
        guard index >= 0 else { throw .unrepresentableArithmetic }
        var digits = 1, remaining = index
        while remaining >= 10 { remaining /= 10; digits += 1 }
        try budget.charge(.stringBytes, prefix.utf8.count + digits)
        return "\(prefix)\(index)"
    }
    private static func sorting(_ count: Int, budget: inout NativeRoutedPEXWorkBudget,
                                isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        guard count > 1 else { try budget.visit(1, isCancelled); return }
        let (cost, overflow) = count.multipliedReportingOverflow(by: 2 * (Int.bitWidth - count.leadingZeroBitCount))
        guard !overflow else { throw .unrepresentableArithmetic }
        try budget.visit(cost, isCancelled)
    }
}
