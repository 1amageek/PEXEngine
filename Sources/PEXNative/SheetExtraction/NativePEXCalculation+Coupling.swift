import PEXCore

extension NativePEXCalculation {
    private struct Projection: Hashable { let x: Int; let y: Int }
    private struct Face: Equatable {
        let bottom: Key
        let top: Key
        let model: PEXCouplingElectricalModel
        let gapMeters: Double
    }

    mutating func couplingCapacitance(_ isCancelled: () -> Bool) throws(NativePEXCalculationError) {
        let pairModels = Dictionary(uniqueKeysWithValues: mesh.model.couplings.map { (Set([$0.firstLayerName, $0.secondLayerName]), $0) })
        for alongX in [true, false] {
            let keys = alongX ? metalKeys : metalKeys.sorted {
                if $0.layer != $1.layer { return $0.layer < $1.layer }
                if $0.x != $1.x { return $0.x < $1.x }
                return $0.y < $1.y
            }
            for index in keys.indices.dropFirst() {
                try mesh.budget.visit(isCancelled)
                let first = keys[index - 1], second = keys[index]
                guard first.layer == second.layer,
                      alongX ? first.y == second.y : first.x == second.x else { continue }
                let gap = alongX ? Int64(mesh.x[second.x]) - Int64(mesh.x[first.x + 1])
                                 : Int64(mesh.y[second.y]) - Int64(mesh.y[first.y + 1])
                guard gap > 0 else { continue }
                guard let model = pairModels[Set([mesh.layers[first.layer].name])] else { throw .inconsistentSnapshot }
                let gapMeters = try NativePEXMath.positive(Double(gap) * mesh.metersPerDatabaseUnit)
                do { try model.gapRange.requireContains(gapMeters, field: "\(mesh.layers[first.layer].name).coplanarGap") }
                catch { throw .electricalModel(error) }
                let length = alongX ? height(first) : width(first)
                let value = try NativePEXMath.term(coefficient: model.sidewallFarads, geometry: Double(length) / Double(gap))
                try addCapacitance(nodeIDs[first]!, nodeIDs[second]!, value, kind: .coplanar)
            }
        }
        var columns: [Projection: [Key]] = [:]
        for key in metalKeys {
            try mesh.budget.visit(isCancelled)
            columns[Projection(x: key.x, y: key.y), default: []].append(key)
        }
        var faces: [Projection: [Face]] = [:]
        // Metal keys are layer-ordered; each column contains planes in stack order.
        for point in columns.keys.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            let planes = columns[point]!
            for index in planes.indices.dropFirst() {
                try mesh.budget.visit(isCancelled)
                let first = planes[index - 1], second = planes[index]
                var blocked = false
                for layer in (first.layer + 1)..<second.layer {
                    try mesh.budget.visit(isCancelled)
                    if mesh.cells[Key(layer: layer, x: point.x, y: point.y)] != nil { blocked = true; break }
                }
                guard !blocked else { continue }
                let lower = mesh.layers[first.layer].conductor!, upper = mesh.layers[second.layer].conductor!
                guard let model = pairModels[Set([lower.layerName, upper.layerName])] else { throw .inconsistentSnapshot }
                let gap = try NativePEXMath.positive(upper.bottomHeightMeters - lower.bottomHeightMeters - lower.thicknessMeters)
                faces[point, default: []].append(Face(bottom: first, top: second, model: model, gapMeters: gap))
            }
        }
        func samePatch(_ first: Face, _ second: Face) -> Bool {
            first.bottom.layer == second.bottom.layer && first.top.layer == second.top.layer
                && mesh.cells[first.bottom]?.componentIndex == mesh.cells[second.bottom]?.componentIndex
                && mesh.cells[first.top]?.componentIndex == mesh.cells[second.top]?.componentIndex
        }
        for point in faces.keys.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            for face in faces[point]! {
                try mesh.budget.visit(isCancelled)
                var perimeter: Int64 = 0
                for (neighbor, length) in [(Projection(x: point.x - 1, y: point.y), height(face.bottom)),
                    (Projection(x: point.x + 1, y: point.y), height(face.bottom)),
                    (Projection(x: point.x, y: point.y - 1), width(face.bottom)),
                    (Projection(x: point.x, y: point.y + 1), width(face.bottom))] {
                    var found = false
                    for candidate in faces[neighbor] ?? [] {
                        try mesh.budget.visit(isCancelled)
                        if samePatch(face, candidate) { found = true; break }
                    }
                    if !found { perimeter += length }
                }
                let dx = try NativePEXMath.positive(Double(width(face.bottom)) * mesh.metersPerDatabaseUnit)
                let dy = try NativePEXMath.positive(Double(height(face.bottom)) * mesh.metersPerDatabaseUnit)
                let area = face.model.areaFaradsPerSquareMeter == 0 ? 0 : try NativePEXMath.positive(dx * dy)
                let edgeRatio: Double
                if face.model.sidewallFarads == 0 || perimeter == 0 {
                    edgeRatio = 0
                } else {
                    // A positive physical ratio must not silently become an absent operator.
                    let length = try NativePEXMath.positive(Double(perimeter) * mesh.metersPerDatabaseUnit)
                    edgeRatio = try NativePEXMath.positive(length / face.gapMeters)
                }
                let value = try NativePEXMath.term(coefficient: face.model.areaFaradsPerSquareMeter, geometry: area)
                    + NativePEXMath.term(coefficient: face.model.sidewallFarads, geometry: edgeRatio)
                try addCapacitance(nodeIDs[face.bottom]!, nodeIDs[face.top]!, value, kind: .interlayer)
            }
        }
    }
}
