import PEXCore

struct NativeRoutedPEXGeometry {
    typealias Input = NativeRoutedPEXInput
    struct PointKey: Hashable { let net: NetName; let layer: String; let x: Int64; let y: Int64 }
    struct Interval: Equatable {
        let low: Int64, high: Int64
        var length: Int64 { high - low }
    }
    let input: Input
    let profile: PEXOpenRCXSourceModel.Profile
    let layers: [String: Input.Layer]
    let levels: [Int: Input.Layer]
    let roles: [NetName: Input.Role]
    let nodes: [NodeRef: Input.Node]
    let terminals: [NodeRef: Input.Terminal]
    let wires: [Input.Wire]
    let vias: [Input.Via]
    let sourceFacts: [Input.SourceFact]
    let conductorUnion: NativeConductorUnion?

    init(input: Input, model: PEXOpenRCXSourceModel, budget: inout NativeRoutedPEXWorkBudget,
         isCancelled: () -> Bool, areaContacts: Bool = false) throws(NativeRoutedPEXError) {
        guard input.selection == model.selection, input.databaseUnitsPerMicron > 0,
              input.databaseUnitsPerMicron <= Int64(UInt32.max), Self.valid(input.dieBounds) else {
            throw .invalidInput(reason: .units, sourceIDs: [])
        }
        try budget.visit(input.sourceArtifacts.count, isCancelled)
        try budget.charge(.inputRecords, input.sourceArtifacts.count)
        let artifacts = Set(input.sourceArtifacts)
        guard artifacts.count == input.sourceArtifacts.count,
              artifacts.contains(input.defArtifactID), artifacts.contains(input.selection.technologyLEFArtifactID),
              artifacts.contains(input.selection.rulesArtifactID) else { throw .invalidInput(reason: .sourceIdentity, sourceIDs: []) }
        for artifact in artifacts {
            try budget.visit(1, isCancelled)
            guard artifact.byteCount > 0, artifact.digest.algorithm == .sha256 else {
                throw .invalidInput(reason: .sourceIdentity, sourceIDs: [])
            }
        }
        var facts: [Input.SourceFact] = [], factSet = Set<Input.SourceFact>()
        func admitFacts(_ values: [Input.SourceFact], _ ids: [String]) throws(NativeRoutedPEXError) {
            guard !values.isEmpty else { throw .invalidInput(reason: .sourceRange, sourceIDs: ids) }
            for value in values {
                try budget.visit(1, isCancelled); try budget.charge(.inputRecords)
                guard artifacts.contains(value.artifactID), value.byteRange.lowerBound >= 0,
                      value.byteRange.upperBound > value.byteRange.lowerBound,
                      UInt64(value.byteRange.upperBound) <= value.artifactID.byteCount else {
                    throw .invalidInput(reason: .sourceRange, sourceIDs: ids)
                }
                if factSet.insert(value).inserted { facts.append(value) }
            }
        }
        func text(_ value: String) throws(NativeRoutedPEXError) {
            try budget.charge(.stringBytes, value.utf8.count)
            guard !value.isEmpty else { throw .invalidInput(reason: .sourceIdentity, sourceIDs: []) }
        }
        var layers: [String: Input.Layer] = [:], levels: [Int: Input.Layer] = [:]
        guard input.layers.count == 6 else { throw .invalidInput(reason: .layer, sourceIDs: []) }
        for layer in input.layers {
            try budget.visit(1, isCancelled); try budget.charge(.inputRecords); try text(layer.name)
            guard (1...6).contains(layer.level), input.selection.routingLayerNames[layer.level - 1] == layer.name,
                  layer.pitchDatabaseUnits > 0, layer.pitchDatabaseUnits <= Int64(Int32.max),
                  layer.defaultWidthDatabaseUnits > 0, layer.defaultWidthDatabaseUnits <= layer.pitchDatabaseUnits,
                  layer.sheetResistanceOhmsPerSquare.isFinite, layer.sheetResistanceOhmsPerSquare > 0,
                  layers.updateValue(layer, forKey: layer.name) == nil, levels.updateValue(layer, forKey: layer.level) == nil,
                  layer.sourceFacts.contains(where: { $0.artifactID == input.selection.technologyLEFArtifactID }),
                  layer.sourceFacts.contains(where: { $0.artifactID == input.defArtifactID }) else {
                throw .invalidInput(reason: .layer, sourceIDs: [layer.name])
            }
            for (origin, derivation, first, die) in [
                (layer.searchOriginX, layer.originDerivationX, layer.firstDEFTrackX, input.dieBounds.minX),
                (layer.searchOriginY, layer.originDerivationY, layer.firstDEFTrackY, input.dieBounds.minY)] {
                guard Self.coordinate(origin) else { throw .invalidInput(reason: .layer, sourceIDs: [layer.name]) }
                switch derivation {
                case .dieLowerLeft:
                    guard first == nil, origin == die else { throw .invalidInput(reason: .layer, sourceIDs: [layer.name]) }
                case .firstDEFTrackMinusHalfDefaultWidth:
                    guard let first, Self.coordinate(first), origin == first - layer.defaultWidthDatabaseUnits / 2 else {
                        throw .invalidInput(reason: .layer, sourceIDs: [layer.name])
                    }
                }
            }
            try admitFacts(layer.sourceFacts, [layer.name])
        }
        var roles: [NetName: Input.Role] = [:]
        for net in input.nets {
            try budget.visit(1, isCancelled); try budget.charge(.inputRecords); try text(net.name.value)
            guard roles.updateValue(net.role, forKey: net.name) == nil else { throw .invalidInput(reason: .net, sourceIDs: [net.name.value]) }
            try admitFacts(net.sourceFacts, [net.name.value])
        }
        var nodes: [NodeRef: Input.Node] = [:], points: [PointKey: [NodeRef]] = [:]
        for node in input.nodes {
            try budget.visit(1, isCancelled); try budget.charge(.inputRecords); try text(node.ref.nodeName.value)
            guard roles[node.ref.netName] != nil, layers[node.layerName] != nil,
                  Self.coordinate(node.x), Self.coordinate(node.y), nodes.updateValue(node, forKey: node.ref) == nil else {
                throw .invalidInput(reason: .node, sourceIDs: [node.ref.nodeName.value])
            }
            let point = PointKey(net: node.ref.netName, layer: node.layerName, x: node.x, y: node.y)
            points[point, default: []].append(node.ref)
            try admitFacts(node.sourceFacts, [node.ref.nodeName.value])
        }
        var ids = Set<String>(), ordinals = Set<Int>()
        for wire in input.wires {
            try budget.visit(1, isCancelled); try budget.charge(.inputRecords); try text(wire.sourceID)
            guard ids.insert(wire.sourceID).inserted, wire.sourceOrdinal >= 0, ordinals.insert(wire.sourceOrdinal).inserted,
                  roles[wire.netName] != nil, layers[wire.layerName] != nil, Self.valid(wire.rect) else {
                throw .invalidInput(reason: .wire, sourceIDs: [wire.sourceID])
            }
            if roles[wire.netName] == .signal {
                guard let a = nodes[wire.sourceNode], let b = nodes[wire.targetNode],
                      a.ref.netName == wire.netName, b.ref.netName == wire.netName,
                      a.layerName == wire.layerName, b.layerName == wire.layerName,
                      wire.sourceNode != wire.targetNode, Self.contains(wire.rect, a.x, a.y), Self.contains(wire.rect, b.x, b.y),
                      wire.axis == .horizontal ? (a.y == b.y && a.x != b.x) : (a.x == b.x && a.y != b.y) else {
                    throw .invalidInput(reason: .wire, sourceIDs: [wire.sourceID])
                }
                let center = wire.axis == .horizontal ? a.y : a.x
                let sum = wire.axis == .horizontal ? wire.rect.minY + wire.rect.maxY : wire.rect.minX + wire.rect.maxX
                guard abs(2 * center - sum) <= 1 else { throw .invalidInput(reason: .wire, sourceIDs: [wire.sourceID]) }
            }
            try admitFacts(wire.sourceFacts, [wire.sourceID])
        }
        for via in input.vias {
            try budget.visit(1, isCancelled); try budget.charge(.inputRecords); try text(via.sourceID)
            guard ids.insert(via.sourceID).inserted, via.sourceOrdinal >= 0, ordinals.insert(via.sourceOrdinal).inserted,
                  roles[via.netName] != nil, !via.cuts.isEmpty, !via.landings.isEmpty else {
                throw .invalidInput(reason: .via, sourceIDs: [via.sourceID])
            }
            for landing in via.landings {
                try budget.visit(1, isCancelled); try budget.charge(.inputRecords)
                guard layers[landing.layerName] != nil, Self.valid(landing.rect) else { throw .invalidInput(reason: .via, sourceIDs: [via.sourceID]) }
                try admitFacts(landing.sourceFacts, [via.sourceID])
            }
            for cut in via.cuts {
                try budget.visit(1, isCancelled); try budget.charge(.inputRecords); try text(cut.layerName)
                guard Self.valid(cut.rect), cut.resistanceOhms.isFinite, cut.resistanceOhms > 0 else {
                    throw .invalidInput(reason: .via, sourceIDs: [via.sourceID])
                }
                try admitFacts(cut.sourceFacts, [via.sourceID])
            }
            if roles[via.netName] == .signal {
                guard let a = nodes[via.sourceNode], let b = nodes[via.targetNode],
                      a.ref.netName == via.netName, b.ref.netName == via.netName, a.x == b.x, a.y == b.y,
                      a.layerName != b.layerName,
                      Set(via.landings.map(\.layerName)) == Set([a.layerName, b.layerName]) else {
                    throw .invalidInput(reason: .via, sourceIDs: [via.sourceID])
                }
                for name in [a.layerName, b.layerName] {
                    let rects = via.landings.filter { $0.layerName == name }.map(\.rect)
                    guard rects.contains(where: { Self.contains($0, a.x, a.y) }) else {
                        throw .invalidInput(reason: .cutContact, sourceIDs: [via.sourceID])
                    }
                    for cut in via.cuts {
                        guard try Self.covered(cut.rect, by: rects, budget: &budget, isCancelled: isCancelled) else {
                            throw .invalidInput(reason: .cutContact, sourceIDs: [via.sourceID])
                        }
                    }
                }
            }
            try admitFacts(via.sourceFacts, [via.sourceID])
        }
        var terminals: [NodeRef: Input.Terminal] = [:]
        for terminal in input.terminals {
            try budget.visit(1, isCancelled); try budget.charge(.inputRecords)
            guard let node = nodes[terminal.ref], roles[terminal.ref.netName] == .signal,
                  terminals.updateValue(terminal, forKey: terminal.ref) == nil, !terminal.contacts.isEmpty else {
                throw .invalidInput(reason: .terminal, sourceIDs: [terminal.ref.nodeName.value])
            }
            var contacted = false
            for contact in terminal.contacts {
                try budget.visit(1, isCancelled); try budget.charge(.inputRecords)
                guard layers[contact.layerName] != nil, Self.valid(contact.rect) else {
                    throw .invalidInput(reason: .terminal, sourceIDs: [terminal.ref.nodeName.value])
                }
                try admitFacts(contact.sourceFacts, [terminal.ref.nodeName.value])
                if contact.layerName == node.layerName && Self.contains(contact.rect, node.x, node.y) {
                    for wire in input.wires {
                        try budget.visit(1, isCancelled)
                        if wire.netName == node.ref.netName && wire.layerName == node.layerName
                            && Self.positiveArea(wire.rect, contact.rect)
                            && (areaContacts || Self.onCenterline(wire, node, nodes)) { contacted = true }
                    }
                    for via in input.vias where via.netName == node.ref.netName {
                        try budget.visit(1, isCancelled)
                        let endpoint = [via.sourceNode, via.targetNode].contains { ref in
                            guard let candidate = nodes[ref] else { return false }
                            return candidate.layerName == node.layerName && candidate.x == node.x && candidate.y == node.y
                        }
                        if endpoint {
                            contacted = contacted || via.landings.contains { $0.layerName == node.layerName && Self.positiveArea($0.rect, contact.rect) }
                        }
                    }
                }
            }
            guard contacted else { throw .invalidInput(reason: .terminal, sourceIDs: [terminal.ref.nodeName.value]) }
            try admitFacts(terminal.sourceFacts, [terminal.ref.nodeName.value])
        }
        for refs in points.values where refs.count > 1 {
            var internalCount = 0
            for ref in refs {
                try budget.visit(1, isCancelled)
                if terminals[ref] == nil { internalCount += 1 }
            }
            guard internalCount <= 1 else {
                throw .invalidInput(reason: .nodeAliases, sourceIDs: refs.map { $0.nodeName.value }.sorted())
            }
        }
        self.input = input; self.profile = model.profile; self.layers = layers; self.levels = levels; self.roles = roles; self.nodes = nodes
        self.terminals = terminals; self.wires = input.wires.sorted { $0.sourceOrdinal < $1.sourceOrdinal }
        self.vias = input.vias.sorted { $0.sourceOrdinal < $1.sourceOrdinal }; self.sourceFacts = facts
        conductorUnion = nil
    }

    /// Query-only geometry after the original source input has already been admitted.
    /// These rectangles carry the checked physical union; they are not new source records.
    init(admitted: NativeRoutedPEXGeometry, queryWires: [Input.Wire], conductorUnion: NativeConductorUnion) {
        input = admitted.input; profile = admitted.profile; layers = admitted.layers; levels = admitted.levels
        roles = admitted.roles; nodes = admitted.nodes; terminals = admitted.terminals
        wires = queryWires; vias = admitted.vias; sourceFacts = admitted.sourceFacts
        self.conductorUnion = conductorUnion
    }
    static func coordinate(_ x: Int64) -> Bool { x >= Int64(Int32.min) && x <= Int64(Int32.max) }
    static func valid(_ r: Input.Rect) -> Bool {
        coordinate(r.minX) && coordinate(r.minY) && coordinate(r.maxX) && coordinate(r.maxY)
            && r.minX < r.maxX && r.minY < r.maxY && r.maxX - r.minX <= Int64(Int32.max) && r.maxY - r.minY <= Int64(Int32.max)
    }
    static func contains(_ r: Input.Rect, _ x: Int64, _ y: Int64) -> Bool { r.minX <= x && x <= r.maxX && r.minY <= y && y <= r.maxY }
    static func positiveArea(_ a: Input.Rect, _ b: Input.Rect) -> Bool { min(a.maxX, b.maxX) > max(a.minX, b.minX) && min(a.maxY, b.maxY) > max(a.minY, b.minY) }
    static func conductiveContact(_ a: Input.Rect, _ b: Input.Rect) -> Bool {
        let x = min(a.maxX, b.maxX) - max(a.minX, b.minX), y = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return x >= 0 && y >= 0 && (x > 0 || y > 0)
    }
    static func onCenterline(_ wire: Input.Wire, _ node: Input.Node, _ nodes: [NodeRef: Input.Node]) -> Bool {
        guard let a = nodes[wire.sourceNode], let b = nodes[wire.targetNode] else { return false }
        return wire.axis == .horizontal ? node.y == a.y && node.x >= min(a.x, b.x) && node.x <= max(a.x, b.x)
            : node.x == a.x && node.y >= min(a.y, b.y) && node.y <= max(a.y, b.y)
    }
    static func covered(_ cut: Input.Rect, by rects: [Input.Rect], budget: inout NativeRoutedPEXWorkBudget,
                        isCancelled: () -> Bool) throws(NativeRoutedPEXError) -> Bool {
        var xs = Set([cut.minX, cut.maxX])
        for r in rects {
            try budget.visit(1, isCancelled)
            if r.minX > cut.minX && r.minX < cut.maxX { xs.insert(r.minX) }
            if r.maxX > cut.minX && r.maxX < cut.maxX { xs.insert(r.maxX) }
        }
        try budget.charge(.coordinateValues, xs.count)
        let sorted = xs.sorted()
        for i in 1..<sorted.count {
            var spans: [Interval] = []
            for r in rects {
                try budget.visit(1, isCancelled)
                if r.minX <= sorted[i - 1] && r.maxX >= sorted[i] {
                    spans.append(.init(low: max(cut.minY, r.minY), high: min(cut.maxY, r.maxY)))
                }
            }
            var y = cut.minY
            for span in spans.sorted(by: { $0.low < $1.low }) {
                try budget.visit(1, isCancelled)
                if span.low > y { return false }
                y = max(y, span.high)
            }
            if y < cut.maxY { return false }
        }
        return true
    }
}
