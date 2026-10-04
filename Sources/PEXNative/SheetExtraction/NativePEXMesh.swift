import LayoutCore
import LayoutVerify
import PEXCore

/// A sparse union of physical coverage. Internal only: no terminal RC result is implied.
struct NativePEXMesh {
    struct Key: Hashable, Comparable {
        let layer: Int
        let x: Int
        let y: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.layer != rhs.layer { return lhs.layer < rhs.layer }
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.x < rhs.x
        }
    }

    struct Cell: Equatable {
        let componentIndex: Int
        var viaDefinitionID: String?
    }

    struct Layer {
        let id: LayoutLayerID
        let name: String
        let conductor: PEXConductorElectricalModel?
    }

    let snapshot: LayoutConductorSnapshot
    let model: PEXElectricalModel
    let metersPerDatabaseUnit: Double
    let maximumCellSpanDatabaseUnits: Int32
    let layers: [Layer]
    let x: [Int32]
    let y: [Int32]
    let cells: [Key: Cell]
    let orderedKeys: [Key]
    let pinContacts: [[Key]]
    var budget: NativePEXWorkBudget

    static func build(
        snapshot: LayoutConductorSnapshot, technology: TechnologyIR, corner: PEXCorner,
        layerNames: [LayoutLayerID: String], maximumCellSpanDatabaseUnits: Int32,
        limits: NativePEXCalculationLimits = .default,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws(NativePEXCalculationError) -> Self {
        var budget = try NativePEXWorkBudget(limits)
        guard maximumCellSpanDatabaseUnits > 0 else { throw .invalidConfiguration }
        try budget.visit(isCancelled)
        for count in [snapshot.footprints.count, snapshot.pins.count, snapshot.components.count,
                      snapshot.contacts.count, layerNames.count, technology.stack.count, technology.vias.count,
                      technology.logicalToPhysicalLayerMap.count, technology.electricalModels?.count ?? 0] {
            try budget.charge(.inputRecords, count)
        }
        for model in technology.electricalModels ?? [] {
            try budget.visit(isCancelled)
            for count in [model.conductors.count, model.vias.count, model.couplings.count,
                          model.calibrationArtifacts.count, model.parameters.count] {
                try budget.charge(.inputRecords, count)
            }
        }
        for pin in snapshot.pins {
            try budget.visit(isCancelled)
            try budget.charge(.inputRecords, pin.bands.count)
        }
        let model: PEXElectricalModel
        do { model = try technology.electricalModel(for: corner) }
        catch { throw .electricalModel(error) }
        guard !snapshot.footprints.isEmpty else { throw .emptyGeometry }
        let meters = 1e-6 / snapshot.coordinateUnits.scale.databaseUnitsPerMicrometer
        guard meters.isFinite, meters > 0 else { throw .invalidUnits }
        let metal = Dictionary(uniqueKeysWithValues: model.conductors.map { ($0.layerName, $0) })
        guard Set(layerNames.values) == Set(technology.stack.map(\.name)),
              Set(layerNames.values).count == layerNames.count else { throw .invalidLayerMapping }
        let reverse = Dictionary(uniqueKeysWithValues: layerNames.map { ($0.value, $0.key) })
        let layers = technology.stack.sorted { $0.order < $1.order }.map {
            Layer(id: reverse[$0.name]!, name: $0.name, conductor: metal[$0.name])
        }
        guard Set(layers.filter { $0.conductor != nil }.map(\.id)) == snapshot.conductiveLayers else {
            throw .invalidLayerMapping
        }
        let layerIndices = Dictionary(uniqueKeysWithValues: layers.enumerated().map { ($0.element.id, $0.offset) })
        let viaModels = Dictionary(uniqueKeysWithValues: model.vias.map { ($0.viaName, $0) })
        var components = [Int](repeating: -1, count: snapshot.footprints.count)
        for (index, component) in snapshot.components.enumerated() {
            try budget.visit(isCancelled)
            try budget.charge(.inputRecords, component.footprintIndices.count)
            for footprint in component.footprintIndices {
                try budget.visit(isCancelled)
                guard components.indices.contains(footprint), components[footprint] == -1 else { throw .inconsistentSnapshot }
                components[footprint] = index
            }
        }
        guard !components.contains(-1) else { throw .inconsistentSnapshot }

        var xs = Set<Int32>(), ys = Set<Int32>()
        func endpoints(_ minimum: Int32, _ maximum: Int32, into values: inout Set<Int32>) throws(NativePEXCalculationError) {
            guard maximum > minimum else { throw .inconsistentSnapshot }
            var current = Int64(minimum)
            while true {
                try budget.visit(isCancelled)
                // The clamped endpoint is within the original checked Int32 interval.
                let value = Int32(current)
                if !values.contains(value) { try budget.charge(.coordinateValues); values.insert(value) }
                if current == Int64(maximum) { break }
                current = min(Int64(maximum), current + Int64(maximumCellSpanDatabaseUnits))
            }
        }
        for footprint in snapshot.footprints {
            try endpoints(footprint.band.minX, footprint.band.maxX, into: &xs)
            try endpoints(footprint.band.minY, footprint.band.maxY, into: &ys)
        }
        for pin in snapshot.pins {
            for band in pin.bands {
                try endpoints(band.minX, band.maxX, into: &xs)
                try endpoints(band.minY, band.maxY, into: &ys)
            }
        }
        try budget.visit(isCancelled)
        let x = xs.sorted(), y = ys.sorted()
        let xi = Dictionary(uniqueKeysWithValues: x.enumerated().map { ($0.element, $0.offset) })
        let yi = Dictionary(uniqueKeysWithValues: y.enumerated().map { ($0.element, $0.offset) })
        var cells: [Key: Cell] = [:]
        for (index, footprint) in snapshot.footprints.enumerated() {
            try budget.visit(isCancelled)
            guard let layer = layerIndices[footprint.layer], (layers[layer].conductor == nil) == footprint.isCut else {
                throw .invalidLayerMapping
            }
            var definition: String?
            if footprint.isCut, case .via(let sourceIndex) = footprint.source {
                guard snapshot.hierarchy.vias.indices.contains(sourceIndex) else { throw .inconsistentSnapshot }
                let id = snapshot.hierarchy.vias[sourceIndex].viaDefinitionID
                guard let via = viaModels[id], via.cutLayerName == layers[layer].name else { throw .unknownViaDefinition(id) }
                definition = id
            }
            guard let x0 = xi[footprint.band.minX], let x1 = xi[footprint.band.maxX],
                  let y0 = yi[footprint.band.minY], let y1 = yi[footprint.band.maxY] else { throw .inconsistentSnapshot }
            for row in y0..<y1 {
                for column in x0..<x1 {
                    try budget.visit(isCancelled)
                    let key = Key(layer: layer, x: column, y: row)
                    if var previous = cells[key] {
                        guard previous.componentIndex == components[index] else { throw .inconsistentSnapshot }
                        if let first = previous.viaDefinitionID, let second = definition, first != second { throw .ambiguousCutModel }
                        if previous.viaDefinitionID == nil { previous.viaDefinitionID = definition }
                        cells[key] = previous
                    } else {
                        try budget.charge(.meshCells)
                        cells[key] = Cell(componentIndex: components[index], viaDefinitionID: definition)
                    }
                }
            }
        }
        try budget.visit(isCancelled)
        let ordered = cells.keys.sorted()
        var pinContacts: [[Key]] = []
        for pin in snapshot.pins {
            try budget.visit(isCancelled)
            guard snapshot.hierarchy.pins.indices.contains(pin.sourcePinIndex),
                  let layer = layerIndices[snapshot.hierarchy.pins[pin.sourcePinIndex].layer],
                  layers[layer].conductor != nil else { throw .inconsistentSnapshot }
            var contacts = Set<Key>()
            for band in pin.bands {
                guard let x0 = xi[band.minX], let x1 = xi[band.maxX],
                      let y0 = yi[band.minY], let y1 = yi[band.maxY] else { throw .inconsistentSnapshot }
                for row in y0..<y1 {
                    for column in x0..<x1 {
                        try budget.visit(isCancelled)
                        let key = Key(layer: layer, x: column, y: row)
                        guard cells[key] != nil else { continue }
                        let overlapX = min(x[column + 1], band.maxX) > max(x[column], band.minX)
                        let overlapY = min(y[row + 1], band.maxY) > max(y[row], band.minY)
                        // Pin regions label positive-area overlap, matching ConductorCapture.
                        guard overlapX && overlapY else { continue }
                        if !contacts.contains(key) { try budget.charge(.pinContacts); contacts.insert(key) }
                    }
                }
            }
            guard Set(contacts.compactMap { cells[$0]?.componentIndex }) == Set(pin.componentIndices) else {
                throw .inconsistentSnapshot
            }
            pinContacts.append(contacts.sorted())
        }
        try budget.visit(isCancelled)
        return Self(snapshot: snapshot, model: model, metersPerDatabaseUnit: meters,
            maximumCellSpanDatabaseUnits: maximumCellSpanDatabaseUnits, layers: layers, x: x, y: y,
            cells: cells, orderedKeys: ordered, pinContacts: pinContacts, budget: budget)
    }
}
