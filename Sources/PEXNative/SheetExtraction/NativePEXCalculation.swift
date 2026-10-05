import PEXCore

struct NativePEXCalculation {
    typealias Key = NativePEXMesh.Key
    struct GroundFringe {
        var minX = 1.0
        var maxX = 1.0
        var minY = 1.0
        var maxY = 1.0
    }
    var mesh: NativePEXMesh
    let metalKeys: [Key]
    let nodeIDs: [Key: Int]
    var nodes: [NativePEXNetwork.Node]
    var resistors: [NativePEXNetwork.Resistor] = []
    var capacitors: [NativePEXNetwork.Capacitor] = []
    // At most one four-face record per occupied metal cell, bounded by meshCells.
    var groundFringe: [Key: GroundFringe] = [:]

    init(mesh: NativePEXMesh, isCancelled: () -> Bool) throws(NativePEXCalculationError) {
        var budget = mesh.budget
        var keys: [Key] = [], nodes: [NativePEXNetwork.Node] = [], ids: [Key: Int] = [:]
        for key in mesh.orderedKeys {
            try budget.visit(isCancelled)
            guard let conductor = mesh.layers[key.layer].conductor else { continue }
            let cell = mesh.cells[key]!
            ids[key] = nodes.count
            keys.append(key)
            nodes.append(.init(kind: .metal, layerName: conductor.layerName, componentIndex: cell.componentIndex,
                minXDatabaseUnits: mesh.x[key.x], maxXDatabaseUnits: mesh.x[key.x + 1],
                minYDatabaseUnits: mesh.y[key.y], maxYDatabaseUnits: mesh.y[key.y + 1],
                heightMeters: try NativePEXMath.nonnegative(conductor.bottomHeightMeters + conductor.thicknessMeters / 2)))
        }
        self.mesh = mesh
        self.mesh.budget = budget
        self.metalKeys = keys
        self.nodeIDs = ids
        self.nodes = nodes
    }

    func width(_ key: Key) -> Int64 { Int64(mesh.x[key.x + 1]) - Int64(mesh.x[key.x]) }
    func height(_ key: Key) -> Int64 { Int64(mesh.y[key.y + 1]) - Int64(mesh.y[key.y]) }

    mutating func addResistance(_ first: Int, _ second: Int, _ value: Double,
                                kind: NativePEXNetwork.Resistor.Kind) throws(NativePEXCalculationError) {
        let ohms = try NativePEXMath.positive(value)
        try mesh.budget.charge(.networkElements)
        resistors.append(.init(kind: kind, nodeA: first, nodeB: second, ohms: ohms))
    }

    mutating func addCapacitance(_ first: Int, _ second: Int?, _ value: Double,
                                 kind: NativePEXNetwork.Capacitor.Kind) throws(NativePEXCalculationError) {
        let farads = try NativePEXMath.nonnegative(value)
        guard farads > 0 else { return }
        try mesh.budget.charge(.networkElements)
        capacitors.append(.init(kind: kind, nodeA: first, nodeB: second, farads: farads))
    }

    mutating func finish(_ isCancelled: () -> Bool) throws(NativePEXCalculationError) -> NativePEXNetwork {
        var pins: [NativePEXNetwork.PinContact] = []
        for (index, contacts) in mesh.pinContacts.enumerated() {
            try mesh.budget.visit(isCancelled)
            var indices: [Int] = []
            for key in contacts {
                try mesh.budget.visit(isCancelled)
                guard let node = nodeIDs[key] else { throw .inconsistentSnapshot }
                indices.append(node)
            }
            pins.append(.init(pinIndex: index, nodeIndices: indices))
        }
        try mesh.budget.visit(isCancelled)
        return NativePEXNetwork(snapshot: mesh.snapshot, model: mesh.model,
            metersPerDatabaseUnit: mesh.metersPerDatabaseUnit, maximumCellSpanDatabaseUnits: mesh.maximumCellSpanDatabaseUnits,
            nodes: nodes, resistors: resistors, capacitors: capacitors, pinContacts: pins)
    }
}
