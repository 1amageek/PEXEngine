import CircuiteFoundation
import DEF
import LEF
import PEXCore
import PEXNative

/// Call-local standard geometry projection; numerical context and network admission remain Native-owned.
struct NativeRoutedPEXStandardGeometry {
    typealias Input = NativeRoutedPEXInput
    struct PointKey: Hashable { let net: NetName; let layer: String; let x: Int64; let y: Int64 }
    struct Master { let definition: LEFMacroDef; let source: NativeRoutedPEXDecodedLEF }
    struct ViaShape: Hashable { let layer: String; let rect: Input.Rect }
    let source: DEFDocument
    let defReference: ArtifactReference
    let technology: NativeRoutedPEXDecodedLEF
    let routeTechnology: NativeRoutedPEXDecodedLEF
    let cornerTechnologies: [NativeRoutedPEXDecodedLEF]
    let selection: PEXOpenRCXSourceModel.Selection
    let units: Int64
    let die: Input.Rect
    var budget: NativeRoutedPEXPreparationBudget
    var layers: [Input.Layer] = []
    var layerByName: [String: Input.Layer] = [:]
    var technologyLayers: [String: LEFLayerDef] = [:]
    var routeLayers: [String: LEFLayerDef] = [:]
    var masters: [String: Master] = [:]
    var components: [String: DEFComponent] = [:]
    var ports: [String: DEFPin] = [:]
    var nets: [Input.Net] = []
    var nodes: [Input.Node] = []
    var wires: [Input.Wire] = []
    var vias: [Input.Via] = []
    var terminals: [Input.Terminal] = []
    var nodeByPoint: [PointKey: NodeRef] = [:]
    var nodePositions: [NodeRef: Input.Node] = [:]
    var reservedNames = Set<NodeRef>()
    var connectedTerminals = Set<NodeRef>()
    var terminalOwners: [String: NetName] = [:]
    var sourceOrdinal = 0
    var internalOrdinal = 0

    var defFact: Input.SourceFact {
        .init(artifactID: defReference.id, byteRange: .init(lowerBound: 0, upperBound: Int(defReference.id.byteCount)))
    }

    init(source: DEFSourceDocument, defReference: ArtifactReference,
         technology: NativeRoutedPEXDecodedLEF, routeTechnology: NativeRoutedPEXDecodedLEF,
         cornerTechnologies: [NativeRoutedPEXDecodedLEF], libraries: [NativeRoutedPEXDecodedLEF],
         selection: PEXOpenRCXSourceModel.Selection, topCell: String,
         budget: NativeRoutedPEXPreparationBudget, isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) {
        var budget = budget
        try budget.visit(isCancelled: isCancelled)
        guard source.document.designName == topCell, !topCell.isEmpty,
              source.unitsDeclaration.dbuPerMicron < 9_007_199_254_740_992,
              let units = Int64(exactly: source.unitsDeclaration.dbuPerMicron), units > 0,
              source.document.dbuPerMicron == source.unitsDeclaration.dbuPerMicron else {
            throw .sourceMismatch("DEF top or explicit database units differ from execution")
        }
        // FIXME(INCOMPLETE_IMPLEMENTATION): The current routed host admits rectangular DIEAREA only.
        // Public preparation must refuse polygon die geometry until its exact Native domain is represented and tested.
        guard let area = source.document.dieArea, area.points.count == 2 else {
            throw .unsupportedSource("Routed extraction requires rectangular source DIEAREA")
        }
        let a = area.points[0], b = area.points[1]
        let die = Input.Rect(minX: Int64(min(a.x, b.x)), minY: Int64(min(a.y, b.y)),
                             maxX: Int64(max(a.x, b.x)), maxY: Int64(max(a.y, b.y)))
        guard die.minX < die.maxX, die.minY < die.maxY else { throw .sourceMismatch("Empty source DIEAREA") }
        self.source = source.document; self.defReference = defReference; self.technology = technology
        self.routeTechnology = routeTechnology; self.cornerTechnologies = cornerTechnologies
        self.selection = selection; self.units = units; self.die = die; self.budget = budget
        for library in libraries {
            try self.budget.visit(isCancelled: isCancelled)
            if library.document.hasDatabaseUnitsDeclaration {
                guard library.document.dbuPerMicron == routeTechnology.document.dbuPerMicron else {
                    throw .sourceMismatch("Cell LEF units differ from the routed technology scope")
                }
            }
            for macro in library.document.macros {
                try self.budget.visit(isCancelled: isCancelled); try self.budget.record(); try self.budget.string(macro.name)
                guard !macro.name.isEmpty, masters.updateValue(.init(definition: macro, source: library), forKey: macro.name) == nil else {
                    throw .sourceMismatch("Duplicate or empty LEF master")
                }
            }
        }
        for component in self.source.components {
            try self.budget.visit(isCancelled: isCancelled); try self.budget.record(); try self.budget.string(component.name)
            guard !component.name.isEmpty, component.placementStatus != nil, component.placementStatus != .unplaced,
                  masters[component.macro] != nil, components.updateValue(component, forKey: component.name) == nil else {
                throw .sourceMismatch("Missing placed master or duplicate DEF instance")
            }
        }
        for port in self.source.pins {
            try self.budget.visit(isCancelled: isCancelled); try self.budget.record(); try self.budget.string(port.name)
            guard !port.name.isEmpty, port.placementStatus != nil, port.placementStatus != .unplaced,
                  ports.updateValue(port, forKey: port.name) == nil else { throw .sourceMismatch("Missing pose or duplicate DEF port") }
        }
        for net in self.source.nets { try reserveTerminalNames(net: net.name, connections: net.connections, isCancelled: isCancelled) }
        for net in self.source.specialNets { try reserveTerminalNames(net: net.name, connections: net.connections, isCancelled: isCancelled) }
    }

    mutating func project(sourceArtifacts: [ArtifactID], isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) -> Input {
        try prepareLayers(isCancelled: isCancelled)
        try prepareRouting(isCancelled: isCancelled)
        try prepareTerminals(isCancelled: isCancelled)
        try budget.visit(isCancelled: isCancelled)
        return .init(selection: selection, defArtifactID: defReference.id, sourceArtifacts: sourceArtifacts,
            databaseUnitsPerMicron: units, dieBounds: die, layers: layers, nets: nets,
            nodes: nodes, wires: wires, vias: vias, terminals: terminals)
    }

    mutating func reserveTerminalNames(net: String, connections: [DEFConnection], isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) {
        for connection in connections {
            try budget.visit(isCancelled: isCancelled); try budget.record()
            let name = try terminalName(connection)
            let ref = NodeRef(netName: NetName(net), nodeName: NodeName(name))
            guard !connection.pinName.isEmpty, !connection.componentName.isEmpty,
                  terminalOwners[name] == nil, reservedNames.insert(ref).inserted else {
                throw .sourceMismatch("Duplicate, multiply-owned or empty source terminal connection")
            }
            try budget.record(); terminalOwners[name] = NetName(net)
        }
    }

    mutating func terminalName(_ connection: DEFConnection) throws(NativeRoutedPEXPreparationError) -> String {
        if connection.componentName == "PIN" {
            try budget.string(connection.pinName)
            return connection.pinName
        }
        let (parts, partsOverflow) = connection.componentName.utf8.count.addingReportingOverflow(connection.pinName.utf8.count)
        let (count, delimiterOverflow) = parts.addingReportingOverflow(1)
        guard !partsOverflow, !delimiterOverflow else { throw .arithmeticOverflow }
        try budget.reserveStringBytes(count)
        return connection.componentName + ":" + connection.pinName
    }

    func grid(_ value: Double) throws(NativeRoutedPEXPreparationError) -> Int64 {
        let scaled = value * Double(units)
        guard value.isFinite, scaled.isFinite, let result = Int32(exactly: scaled.rounded()),
              Double(result) / Double(units) == value else { throw .sourceMismatch("Source coordinate is off the exact DEF integer grid") }
        return Int64(result)
    }
    func add(_ a: Int64, _ b: Int64) throws(NativeRoutedPEXPreparationError) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow, Int32(exactly: value) != nil else { throw .arithmeticOverflow }
        return value
    }
    func transform(_ x: Int64, _ y: Int64, orientation: DEFOrientation) -> (Int64, Int64) {
        switch orientation {
        case .n: (x, y)
        case .s: (-x, -y)
        case .e: (y, -x)
        case .w: (-y, x)
        case .fn: (-x, y)
        case .fs: (x, -y)
        case .fe: (-y, -x)
        case .fw: (y, x)
        }
    }
    func posed(_ rect: Input.Rect, orientation: DEFOrientation, x: Int64, y: Int64) throws(NativeRoutedPEXPreparationError) -> Input.Rect {
        let a = transform(rect.minX, rect.minY, orientation: orientation)
        let b = transform(rect.maxX, rect.maxY, orientation: orientation)
        return try .init(minX: add(min(a.0, b.0), x), minY: add(min(a.1, b.1), y),
                         maxX: add(max(a.0, b.0), x), maxY: add(max(a.1, b.1), y))
    }
    func lefRect(_ rect: LEFRect) throws(NativeRoutedPEXPreparationError) -> Input.Rect {
        guard rect.mask == nil else { throw .unsupportedSource("Masked LEF geometry is outside this routed profile") }
        let result = try Input.Rect(minX: grid(rect.x1), minY: grid(rect.y1), maxX: grid(rect.x2), maxY: grid(rect.y2))
        guard result.minX < result.maxX, result.minY < result.maxY else { throw .sourceMismatch("Empty source LEF rectangle") }
        return result
    }
    mutating func node(net: NetName, layer: String, x: Int64, y: Int64, facts: [Input.SourceFact],
                       isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) -> NodeRef {
        try budget.visit(isCancelled: isCancelled)
        let key = PointKey(net: net, layer: layer, x: x, y: y)
        if let existing = nodeByPoint[key] { return existing }
        var ref: NodeRef
        repeat {
            try budget.visit(isCancelled: isCancelled)
            try budget.reserveGeneratedName(prefix: "__PEX_INTERNAL_", ordinal: internalOrdinal)
            ref = .init(netName: net, nodeName: NodeName("__PEX_INTERNAL_\(internalOrdinal)"))
            let (next, overflow) = internalOrdinal.addingReportingOverflow(1)
            guard !overflow else { throw .arithmeticOverflow }; internalOrdinal = next
        } while reservedNames.contains(ref)
        try budget.record(3)
        let value = Input.Node(ref: ref, layerName: layer, x: x, y: y, sourceFacts: facts)
        nodes.append(value); nodePositions[ref] = value; nodeByPoint[key] = ref
        return ref
    }
    mutating func ordinal() throws(NativeRoutedPEXPreparationError) -> Int {
        let result = sourceOrdinal
        let (next, overflow) = sourceOrdinal.addingReportingOverflow(1)
        guard !overflow else { throw .arithmeticOverflow }; sourceOrdinal = next; return result
    }
}
