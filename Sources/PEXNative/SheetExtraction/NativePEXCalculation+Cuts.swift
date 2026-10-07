import PEXCore

extension NativePEXCalculation {
    mutating func cutResistance(_ isCancelled: () -> Bool) throws(NativePEXCalculationError) {
        let layerNamesByID = Dictionary(uniqueKeysWithValues: mesh.layers.map { ($0.id, $0.name) })
        let layerIndices = Dictionary(uniqueKeysWithValues: mesh.layers.enumerated().map { ($0.element.name, $0.offset) })
        var visited = Set<Key>()
        for seed in mesh.orderedKeys where mesh.layers[seed.layer].conductor == nil {
            try mesh.budget.visit(isCancelled)
            guard !visited.contains(seed) else { continue }
            visited.insert(seed)
            var group = [seed], cursor = 0
            var names = Set<String>()
            while cursor < group.count {
                let key = group[cursor]; cursor += 1
                try mesh.budget.visit(isCancelled)
                if let name = mesh.cells[key]?.viaDefinitionID { names.insert(name) }
                for neighbor in [Key(layer: key.layer, x: key.x - 1, y: key.y), Key(layer: key.layer, x: key.x + 1, y: key.y),
                                 Key(layer: key.layer, x: key.x, y: key.y - 1), Key(layer: key.layer, x: key.x, y: key.y + 1)] {
                    try mesh.budget.visit(isCancelled)
                    guard mesh.cells[neighbor] != nil, !visited.contains(neighbor) else { continue }
                    visited.insert(neighbor); group.append(neighbor)
                }
            }
            guard names.count <= 1 else { throw .ambiguousCutModel }
            let x0 = group.map(\.x).min()!, x1 = group.map(\.x).max()! + 1
            let y0 = group.map(\.y).min()!, y1 = group.map(\.y).max()! + 1
            let (expected, overflow) = (x1 - x0).multipliedReportingOverflow(by: y1 - y0)
            guard !overflow, expected == group.count else { throw .unsupportedCutGeometry }
            let dx = Int64(mesh.x[x1]) - Int64(mesh.x[x0]), dy = Int64(mesh.y[y1]) - Int64(mesh.y[y0])
            let widthMeters = try NativePEXMath.positive(Double(dx) * mesh.metersPerDatabaseUnit)
            let heightMeters = try NativePEXMath.positive(Double(dy) * mesh.metersPerDatabaseUnit)
            var candidates: [PEXViaElectricalModel] = []
            for via in mesh.model.vias {
                try mesh.budget.visit(isCancelled)
                guard via.cutLayerName == mesh.layers[seed.layer].name,
                      names.isEmpty || names.contains(via.viaName) else { continue }
                if widthMeters >= via.cutWidthRange.minimumMeters, widthMeters <= via.cutWidthRange.maximumMeters,
                   heightMeters >= via.cutHeightRange.minimumMeters, heightMeters <= via.cutHeightRange.maximumMeters {
                    candidates.append(via)
                }
            }
            guard !candidates.isEmpty else {
                throw .electricalModel(.outOfRange(field: "\(mesh.layers[seed.layer].name).cutDimensions"))
            }
            // Admit every actual selected material before choosing a two-electrode law.
            var contactedMaterials = Set<String>()
            for contact in mesh.snapshot.contacts {
                try mesh.budget.visit(isCancelled)
                guard mesh.snapshot.footprints.indices.contains(contact.firstFootprint),
                      mesh.snapshot.footprints.indices.contains(contact.secondFootprint) else { throw .inconsistentSnapshot }
                let first = mesh.snapshot.footprints[contact.firstFootprint]
                let second = mesh.snapshot.footprints[contact.secondFootprint]
                let cutIndex: Int, materialIndex: Int
                if first.isCut && first.layer == mesh.layers[seed.layer].id {
                    cutIndex = contact.firstFootprint; materialIndex = contact.secondFootprint
                } else if second.isCut && second.layer == mesh.layers[seed.layer].id {
                    cutIndex = contact.secondFootprint; materialIndex = contact.firstFootprint
                } else { continue }
                let cut = mesh.snapshot.footprints[cutIndex], material = mesh.snapshot.footprints[materialIndex]
                guard !material.isCut, mesh.snapshot.conductiveLayers.contains(material.layer),
                      cut.band.minX < mesh.x[x1], cut.band.maxX > mesh.x[x0],
                      cut.band.minY < mesh.y[y1], cut.band.maxY > mesh.y[y0] else { continue }
                guard let materialName = layerNamesByID[material.layer] else { throw .invalidLayerMapping }
                try mesh.budget.visit(isCancelled)
                do {
                    if try mesh.snapshot.hasElectricalContact(footprintAt: cutIndex, with: mesh.snapshot, footprintAt: materialIndex) {
                        contactedMaterials.insert(materialName)
                    }
                } catch { throw .inconsistentSnapshot }
            }
            guard contactedMaterials.count <= 2 else { throw .ambiguousCutModel }
            let component = mesh.cells[seed]!.componentIndex
            var admitted: [(PEXViaElectricalModel, Int, Int)] = []
            for candidate in candidates {
                try mesh.budget.visit(isCancelled)
                guard contactedMaterials == Set([candidate.bottomLayerName, candidate.topLayerName]) else { continue }
                guard let bottom = layerIndices[candidate.bottomLayerName], let top = layerIndices[candidate.topLayerName],
                      mesh.layers[bottom].conductor != nil, mesh.layers[top].conductor != nil else { throw .invalidLayerMapping }
                var complete = true
                for key in group {
                    try mesh.budget.visit(isCancelled)
                    for layer in [bottom, top] {
                        try mesh.budget.visit(isCancelled)
                        let electrode = Key(layer: layer, x: key.x, y: key.y)
                        if nodeIDs[electrode] == nil || mesh.cells[electrode]?.componentIndex != component { complete = false }
                    }
                    if !complete { break }
                }
                if complete { admitted.append((candidate, bottom, top)) }
            }
            guard admitted.count == 1 else {
                if admitted.isEmpty { throw .incompleteCutContact }
                throw .ambiguousCutModel
            }
            let (via, bottom, top) = admitted[0]
            let lower = mesh.layers[bottom].conductor!, upper = mesh.layers[top].conductor!
            let cutNode = nodes.count
            nodes.append(.init(kind: .cut(viaName: via.viaName), layerName: via.cutLayerName, componentIndex: component,
                minXDatabaseUnits: mesh.x[x0], maxXDatabaseUnits: mesh.x[x1], minYDatabaseUnits: mesh.y[y0], maxYDatabaseUnits: mesh.y[y1],
                heightMeters: try NativePEXMath.positive((lower.bottomHeightMeters + lower.thicknessMeters) / 2 + upper.bottomHeightMeters / 2)))
            let totalArea = Double(dx) * Double(dy)
            for key in group.sorted() {
                try mesh.budget.visit(isCancelled)
                let ratio = totalArea / (Double(width(key)) * Double(height(key)))
                let resistance = try NativePEXMath.positive(via.resistanceOhmsPerCut / 2 * ratio)
                for layer in [bottom, top] {
                    try addResistance(cutNode, nodeIDs[Key(layer: layer, x: key.x, y: key.y)]!, resistance, kind: .cut)
                }
            }
        }
    }
}
