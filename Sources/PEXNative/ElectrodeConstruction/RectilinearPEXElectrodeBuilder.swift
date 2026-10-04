import PEXCore

public struct RectilinearPEXElectrodeBuilder: NativePEXElectrodeBuilding {
    public init() {}

    private struct Plane: Hashable {
        let layer: String
        let alongX: Bool
        let coordinate: Int32
    }
    private struct FaceKey: Hashable {
        let plane: Plane
        let side: NativePEXElectrodeFace.Side
        let begin: Int32
        let end: Int32
    }
    private struct Entry {
        let node: Int
        let face: NativePEXElectrodeFace
    }
    private struct Span {
        let begin: Int32
        let end: Int32
    }

    public func build(network: NativePEXNetwork, bindings: [NativePEXElectrodeBinding],
                      limits: NativePEXElectrodeLimits = .default,
                      isCancelled: () -> Bool = { Task.isCancelled })
        throws(NativePEXElectrodeError) -> NativePEXElectrodeNetwork {
        var budget = try NativePEXElectrodeBudget(limits)
        try budget.visit(isCancelled)
        let snapshot = network.snapshot
        guard network.pinContacts.count == snapshot.pins.count else { throw .invalidNetwork }
        try budget.charge(.inputRecords, snapshot.pins.count)
        try budget.charge(.inputRecords, bindings.count)
        var admitted = [NativePEXElectrodeBinding?](repeating: nil, count: snapshot.pins.count)
        var terminals: Set<NodeRef> = []
        for binding in bindings {
            try budget.visit(isCancelled)
            try admitIdentifier(binding.terminal.netName.value, budget: &budget, isCancelled: isCancelled)
            try admitIdentifier(binding.terminal.nodeName.value, budget: &budget, isCancelled: isCancelled)
            guard admitted.indices.contains(binding.pinIndex), admitted[binding.pinIndex] == nil,
                  !binding.terminal.netName.value.isEmpty, !binding.terminal.nodeName.value.isEmpty,
                  !binding.terminal.netName.value.allSatisfy(\.isWhitespace),
                  !binding.terminal.nodeName.value.allSatisfy(\.isWhitespace) else { throw .invalidBinding(pinIndex: binding.pinIndex) }
            guard terminals.insert(binding.terminal).inserted else { throw .duplicateTerminal }
            try budget.charge(.faceRecords, binding.faces.count)
            admitted[binding.pinIndex] = binding
        }
        for index in admitted.indices {
            try budget.visit(isCancelled)
            guard admitted[index] != nil else { throw .missingBinding(pinIndex: index) }
        }

        var planes: [Plane: [Entry]] = [:]
        var faces: Set<FaceKey> = []
        var sheet: [String: Double] = [:]
        try budget.charge(.inputRecords, network.model.conductors.count)
        for conductor in network.model.conductors {
            try budget.visit(isCancelled)
            try admitIdentifier(conductor.layerName, budget: &budget, isCancelled: isCancelled)
            let value = conductor.resistivityOhmMeters / conductor.thicknessMeters
            guard value.isFinite, value > 0, sheet.updateValue(value, forKey: conductor.layerName) == nil else { throw .invalidNetwork }
        }
        try budget.charge(.inputRecords, network.nodes.count)
        for (index, node) in network.nodes.enumerated() {
            try budget.visit(isCancelled)
            guard snapshot.components.indices.contains(node.componentIndex),
                  node.minXDatabaseUnits < node.maxXDatabaseUnits, node.minYDatabaseUnits < node.maxYDatabaseUnits else { throw .invalidNetwork }
            guard node.kind == .metal else { continue }
            try admitIdentifier(node.layerName, budget: &budget, isCancelled: isCancelled)
            guard sheet[node.layerName] != nil else { throw .invalidNetwork }
            try budget.charge(.faceRecords, 4)
            for side in [NativePEXElectrodeFace.Side.minX, .maxX, .minY, .maxY] {
                let coordinate: Int32
                switch side {
                case .minX: coordinate = node.minXDatabaseUnits
                case .maxX: coordinate = node.maxXDatabaseUnits
                case .minY: coordinate = node.minYDatabaseUnits
                case .maxY: coordinate = node.maxYDatabaseUnits
                }
                let begin = side.alongX ? node.minXDatabaseUnits : node.minYDatabaseUnits
                let end = side.alongX ? node.maxXDatabaseUnits : node.maxYDatabaseUnits
                let plane = Plane(layer: node.layerName, alongX: side.alongX, coordinate: coordinate)
                guard faces.insert(FaceKey(plane: plane, side: side, begin: begin, end: end)).inserted else { throw .invalidNetwork }
                planes[plane, default: []].append(Entry(node: index,
                    face: .init(side: side, coordinate: coordinate, begin: begin, end: end)))
            }
        }

        var ports: [NativePEXElectrodeNetwork.Port] = []
        var contacts: [NativePEXElectrodeNetwork.Contact] = []
        var claimed: [Plane: [(pin: Int, face: NativePEXElectrodeFace)]] = [:]
        for pinIndex in snapshot.pins.indices {
            try budget.visit(isCancelled)
            let pin = snapshot.pins[pinIndex], binding = admitted[pinIndex]!
            let incidence = network.pinContacts[pinIndex]
            guard incidence.pinIndex == pinIndex else { throw .invalidNetwork }
            try budget.charge(.inputRecords, incidence.nodeIndices.count)
            try budget.charge(.inputRecords, pin.bands.count)
            try budget.charge(.inputRecords, pin.componentIndices.count)
            var pinNodes: Set<Int> = []
            for nodeIndex in incidence.nodeIndices {
                try budget.visit(isCancelled)
                guard network.nodes.indices.contains(nodeIndex), network.nodes[nodeIndex].kind == .metal,
                      pinNodes.insert(nodeIndex).inserted else { throw .invalidNetwork }
            }
            let components = Set(pinNodes.map { network.nodes[$0].componentIndex })
            guard components == Set(pin.componentIndices) else { throw .invalidNetwork }
            guard components.count <= 1 else { throw .ambiguousPinContact(pinIndex: pinIndex, componentIndices: components.sorted()) }
            let portIndex = ports.count
            if components.isEmpty {
                guard binding.faces.isEmpty else { throw .uncoveredFace(pinIndex: pinIndex, faceIndex: 0) }
                ports.append(.init(pinIndex: pinIndex, terminal: binding.terminal, componentIndex: nil))
                continue
            }
            guard !binding.faces.isEmpty else { throw .invalidBinding(pinIndex: pinIndex) }
            guard let layer = pinNodes.first.map({ network.nodes[$0].layerName }),
                  pinNodes.allSatisfy({ network.nodes[$0].layerName == layer }), let resistance = sheet[layer] else { throw .invalidNetwork }
            for (faceIndex, face) in binding.faces.enumerated() {
                try budget.visit(isCancelled)
                guard face.begin < face.end else { throw .invalidFace(pinIndex: pinIndex, faceIndex: faceIndex) }
                let plane = Plane(layer: layer, alongX: face.side.alongX, coordinate: face.coordinate)
                for old in claimed[plane] ?? [] {
                    try budget.visit(isCancelled)
                    if old.face.side == face.side, min(old.face.end, face.end) > max(old.face.begin, face.begin) {
                        throw .overlappingElectrodes(firstPinIndex: old.pin, secondPinIndex: pinIndex)
                    }
                }
                var coverage: [Span] = []
                for entry in planes[plane] ?? [] {
                    try budget.visit(isCancelled)
                    guard entry.face.side == face.side, pinNodes.contains(entry.node),
                          min(entry.face.end, face.end) > max(entry.face.begin, face.begin) else { continue }
                    let opposite = FaceKey(plane: plane, side: face.side.opposite, begin: entry.face.begin, end: entry.face.end)
                    guard !faces.contains(opposite) else { continue }
                    var spans: [Span] = []
                    for band in pin.bands {
                        try budget.visit(isCancelled)
                        let normalMin = face.side.alongX ? band.minY : band.minX
                        let normalMax = face.side.alongX ? band.maxY : band.maxX
                        guard normalMin <= face.coordinate, face.coordinate <= normalMax else { continue }
                        let begin = max(face.begin, entry.face.begin, face.side.alongX ? band.minX : band.minY)
                        let end = min(face.end, entry.face.end, face.side.alongX ? band.maxX : band.maxY)
                        if begin < end {
                            try budget.charge(.faceRecords)
                            spans.append(Span(begin: begin, end: end))
                        }
                    }
                    let fragments = try merge(spans, budget: &budget, isCancelled: isCancelled)
                    let node = network.nodes[entry.node]
                    let normalSpan = face.side.alongX ? Int64(node.maxYDatabaseUnits) - Int64(node.minYDatabaseUnits)
                                                     : Int64(node.maxXDatabaseUnits) - Int64(node.minXDatabaseUnits)
                    for fragment in fragments {
                        try budget.visit(isCancelled)
                        let ratio = Double(normalSpan) / (2 * Double(Int64(fragment.end) - Int64(fragment.begin)))
                        let ohms = resistance * ratio
                        guard ratio.isFinite, ratio > 0, ohms.isFinite, ohms > 0 else { throw .numericFailure }
                        try budget.charge(.contacts)
                        contacts.append(.init(portIndex: portIndex, nodeIndex: entry.node,
                            face: .init(side: face.side, coordinate: face.coordinate, begin: fragment.begin, end: fragment.end), ohms: ohms))
                        coverage.append(fragment)
                    }
                }
                let complete = try merge(coverage, budget: &budget, isCancelled: isCancelled)
                guard complete.count == 1, complete[0].begin == face.begin, complete[0].end == face.end else {
                    throw .uncoveredFace(pinIndex: pinIndex, faceIndex: faceIndex)
                }
                claimed[plane, default: []].append((pinIndex, face))
            }
            ports.append(.init(pinIndex: pinIndex, terminal: binding.terminal, componentIndex: components.first))
        }
        try budget.visit(isCancelled)
        return NativePEXElectrodeNetwork(network: network, ports: ports, contacts: contacts)
    }

    private func admitIdentifier(_ value: String, budget: inout NativePEXElectrodeBudget, isCancelled: () -> Bool)
        throws(NativePEXElectrodeError) {
        // Admit inspected UTF-8 bytes before Unicode validation, equality or hashing.
        for _ in value.utf8 {
            try budget.visit(isCancelled)
            try budget.charge(.inputRecords)
        }
    }

    private func merge(_ spans: [Span], budget: inout NativePEXElectrodeBudget, isCancelled: () -> Bool)
        throws(NativePEXElectrodeError) -> [Span] {
        try budget.visit(isCancelled)
        // Ordering cost is bounded by admitted face/input records; no geometry is rematerialized.
        let ordered = spans.sorted { $0.begin == $1.begin ? $0.end < $1.end : $0.begin < $1.begin }
        var result: [Span] = []
        for span in ordered {
            try budget.visit(isCancelled)
            if let previous = result.last, span.begin <= previous.end {
                result[result.count - 1] = Span(begin: previous.begin, end: max(previous.end, span.end))
            } else { result.append(span) }
        }
        return result
    }
}
