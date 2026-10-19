import PEXCore

extension NativePEXCalculation {
    mutating func sheetResistance(_ isCancelled: () -> Bool) throws(NativePEXCalculationError) {
        // Run spans describe physical coverage; mesh subdivision does not narrow the conductor.
        var horizontal = [Int64](repeating: 0, count: metalKeys.count)
        var vertical = horizontal
        let columns = metalKeys.sorted {
            if $0.layer != $1.layer { return $0.layer < $1.layer }
            if $0.x != $1.x { return $0.x < $1.x }
            return $0.y < $1.y
        }
        for (keys, alongX) in [(metalKeys, true), (columns, false)] {
            var start = 0
            while start < keys.count {
                try mesh.budget.visit(isCancelled)
                var end = start + 1
                while end < keys.count {
                    try mesh.budget.visit(isCancelled)
                    let previous = keys[end - 1], next = keys[end]
                    guard previous.layer == next.layer,
                          alongX ? (previous.y == next.y && previous.x + 1 == next.x)
                                 : (previous.x == next.x && previous.y + 1 == next.y) else { break }
                    end += 1
                }
                let span = alongX ? Int64(mesh.x[keys[end - 1].x + 1]) - Int64(mesh.x[keys[start].x])
                                 : Int64(mesh.y[keys[end - 1].y + 1]) - Int64(mesh.y[keys[start].y])
                for index in start..<end {
                    try mesh.budget.visit(isCancelled)
                    let id = nodeIDs[keys[index]]!
                    if alongX { horizontal[id] = span } else { vertical[id] = span }
                }
                start = end
            }
        }
        var sheetValues: [Int: Double] = [:]
        for key in metalKeys {
            try mesh.budget.visit(isCancelled)
            let conductor = mesh.layers[key.layer].conductor!, id = nodeIDs[key]!
            let physicalWidth = try NativePEXMath.positive(Double(min(horizontal[id], vertical[id])) * mesh.metersPerDatabaseUnit)
            let physicalLength = try NativePEXMath.positive(Double(max(horizontal[id], vertical[id])) * mesh.metersPerDatabaseUnit)
            do {
                try conductor.widthRange.requireContains(physicalWidth, field: "\(conductor.layerName).occupiedWidth")
                try conductor.lengthRange.requireContains(physicalLength, field: "\(conductor.layerName).occupiedLength")
                if sheetValues[key.layer] == nil { sheetValues[key.layer] = try conductor.sheetResistanceOhms() }
            } catch { throw .electricalModel(error) }
            for neighbor in [Key(layer: key.layer, x: key.x + 1, y: key.y), Key(layer: key.layer, x: key.x, y: key.y + 1)] {
                try mesh.budget.visit(isCancelled)
                guard let other = nodeIDs[neighbor] else { continue }
                guard mesh.cells[neighbor]?.componentIndex == mesh.cells[key]?.componentIndex else { throw .inconsistentSnapshot }
                // The dimensionless ratio is computed before SI scaling, avoiding needless underflow.
                let resistance: Double
                do {
                    resistance = try NativeSheetResistanceOperators.sharedFace(sheetOhms: sheetValues[key.layer]!,
                        normalSpanA: neighbor.x != key.x ? width(key) : height(key),
                        normalSpanB: neighbor.x != key.x ? width(neighbor) : height(neighbor),
                        faceLength: neighbor.x != key.x ? height(key) : width(key))
                } catch { throw .numericFailure }
                try addResistance(id, other, resistance, kind: .sheet)
            }
        }
    }

    mutating func groundCapacitance(_ isCancelled: () -> Bool) throws(NativePEXCalculationError) {
        for key in metalKeys {
            try mesh.budget.visit(isCancelled)
            let conductor = mesh.layers[key.layer].conductor!
            let dx = try NativePEXMath.positive(Double(width(key)) * mesh.metersPerDatabaseUnit)
            let dy = try NativePEXMath.positive(Double(height(key)) * mesh.metersPerDatabaseUnit)
            var perimeterDatabaseUnits: Int64 = 0
            var perimeterMeters = 0.0
            let screened = mesh.model.law == .singlePlaneCoplanarGroundV1
            let fractions = groundFringe[key] ?? GroundFringe()
            for (neighbor, length, fraction) in [(Key(layer: key.layer, x: key.x - 1, y: key.y), height(key), fractions.minX),
                (Key(layer: key.layer, x: key.x + 1, y: key.y), height(key), fractions.maxX),
                (Key(layer: key.layer, x: key.x, y: key.y - 1), width(key), fractions.minY),
                (Key(layer: key.layer, x: key.x, y: key.y + 1), width(key), fractions.maxY)] {
                try mesh.budget.visit(isCancelled)
                guard nodeIDs[neighbor] == nil else { continue }
                if screened {
                    let physicalLength = try NativePEXMath.positive(Double(length) * mesh.metersPerDatabaseUnit)
                    perimeterMeters = try NativePEXMath.nonnegative(perimeterMeters
                        + NativePEXMath.term(coefficient: fraction, geometry: physicalLength))
                } else { perimeterDatabaseUnits += length }
            }
            let area = conductor.groundAreaFaradsPerSquareMeter == 0 ? 0 : try NativePEXMath.positive(dx * dy)
            let perimeter = screened ? perimeterMeters : Double(perimeterDatabaseUnits) * mesh.metersPerDatabaseUnit
            let value = try NativePEXMath.term(coefficient: conductor.groundAreaFaradsPerSquareMeter, geometry: area)
                + NativePEXMath.term(coefficient: conductor.groundPerimeterFaradsPerMeter, geometry: perimeter)
            try addCapacitance(nodeIDs[key]!, nil, value, kind: .ground)
        }
    }
}
