import DEF
import LEF
import PEXCore

extension NativeRoutedPEXStandardGeometry {
    mutating func prepareLayers(isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) {
        guard routeTechnology.document.hasDatabaseUnitsDeclaration,
              routeTechnology.document.dbuPerMicron < 9_007_199_254_740_992,
              let techUnits = Int64(exactly: routeTechnology.document.dbuPerMicron),
              techUnits >= units, techUnits % units == 0 else {
            throw .sourceMismatch("Routed LEF must declare compatible exact database units")
        }
        for corner in cornerTechnologies {
            try budget.visit(isCancelled: isCancelled)
            guard corner.document.hasDatabaseUnitsDeclaration, corner.document.dbuPerMicron == Double(techUnits) else {
                throw .sourceMismatch("Requested corner technology units differ from the routed source scope")
            }
        }
        for layer in technology.document.layers {
            try budget.visit(isCancelled: isCancelled); try budget.record(); try budget.string(layer.name)
            guard technologyLayers.updateValue(layer, forKey: layer.name) == nil else { throw .sourceMismatch("Duplicate full technology layer") }
        }
        for layer in routeTechnology.document.layers {
            try budget.visit(isCancelled: isCancelled); try budget.record(); try budget.string(layer.name)
            guard routeLayers.updateValue(layer, forKey: layer.name) == nil else { throw .sourceMismatch("Duplicate routed technology layer") }
        }
        var orderedRoutingNames: [String] = []
        for layer in technology.document.layers where layer.type == .routing {
            try budget.visit(isCancelled: isCancelled); try budget.record(); orderedRoutingNames.append(layer.name)
        }
        guard orderedRoutingNames == selection.routingLayerNames else {
            throw .sourceMismatch("Six source routing layers must match the explicit rule order")
        }
        for (index, name) in selection.routingLayerNames.enumerated() {
            try budget.visit(isCancelled: isCancelled)
            guard let source = technologyLayers[name], source.type == .routing,
                  let widthValue = source.width, let pitchValue = source.pitch,
                  let direction = source.direction, let resistance = source.resistance,
                  resistance.isFinite, resistance > 0 else { throw .sourceMismatch("Missing source routing WIDTH/PITCH/DIRECTION/resistance") }
            let width = try grid(widthValue), pitch = try grid(pitchValue.x)
            guard width > 0, width.isMultiple(of: 2), pitch > 0, width <= pitch, try grid(pitchValue.y) > 0 else {
                throw .unsupportedSource("Routing dimensions require positive exact integer DBU and even default width")
            }
            var firstX: Int64?, firstY: Int64?
            for track in self.source.tracks {
                try budget.visit(isCancelled: isCancelled)
                var matches = false
                for trackLayer in track.layerNames { try budget.visit(isCancelled: isCancelled); matches = matches || trackLayer == name }
                guard matches else { continue }
                guard track.numTracks > 0, track.step > 0 else { throw .sourceMismatch("Invalid source TRACKS declaration") }
                if track.direction == .x {
                    guard firstX == nil else { throw .unsupportedSource("Multiple X TRACKS domains for one routing layer") }
                    firstX = Int64(track.start)
                } else {
                    guard firstY == nil else { throw .unsupportedSource("Multiple Y TRACKS domains for one routing layer") }
                    firstY = Int64(track.start)
                }
            }
            let originX: Int64
            let originY: Int64
            if let firstX { originX = try add(firstX, -width / 2) } else { originX = die.minX }
            if let firstY { originY = try add(firstY, -width / 2) } else { originY = die.minY }
            let layer = Input.Layer(name: name, level: index + 1,
                preferredDirection: direction == .horizontal ? .horizontal : .vertical,
                // Pinned OpenDB getPitch() returns source pitch X, including an anisotropic declaration.
                pitchDatabaseUnits: pitch, defaultWidthDatabaseUnits: width, sheetResistanceOhmsPerSquare: resistance,
                searchOriginX: originX,
                searchOriginY: originY,
                originDerivationX: firstX == nil ? .dieLowerLeft : .firstDEFTrackMinusHalfDefaultWidth,
                originDerivationY: firstY == nil ? .dieLowerLeft : .firstDEFTrackMinusHalfDefaultWidth,
                firstDEFTrackX: firstX, firstDEFTrackY: firstY,
                sourceFacts: [defFact, technology.fact, routeTechnology.fact])
            try budget.record(2); layers.append(layer); layerByName[name] = layer
        }
    }

    mutating func checkUsedLayer(_ name: String, isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) {
        try budget.visit(isCancelled: isCancelled)
        guard let routed = routeLayers[name], let full = technologyLayers[name],
              routed.type == full.type else { throw .sourceMismatch("Used routing/cut layer is absent from its exact source views") }
        for corner in cornerTechnologies {
            var found: LEFLayerDef?
            for candidate in corner.document.layers {
                try budget.visit(isCancelled: isCancelled)
                if candidate.name == name {
                    guard found == nil else { throw .sourceMismatch("Ambiguous used corner layer") }; found = candidate
                }
            }
            guard let target = found, target.type == routed.type,
                  target.width == routed.width else { throw .sourceMismatch("Used layer WIDTH or type differs across exact technology views") }
            if routed.type == .routing {
                guard target.direction == routed.direction,
                      target.pitch?.x == routed.pitch?.x, target.pitch?.y == routed.pitch?.y else {
                    throw .sourceMismatch("Used layer PITCH or DIRECTION differs across exact technology views")
                }
            }
        }
    }
}
