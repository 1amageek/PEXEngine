import PEXCore

extension UnionSheetRoutedPEXCalculation {
    mutating func unionSources(_ isCancelled: @Sendable () -> Bool)
        throws(NativeRoutedPEXError) -> [NativeConductorUnion.Source] {
        var result: [NativeConductorUnion.Source] = []
        func facts(_ values: [Input.SourceFact], budget: inout NativeRoutedPEXWorkBudget)
            throws(NativeRoutedPEXError) -> [NativeConductorUnion.SourceFact] {
            try budget.charge(.inputRecords, values.count)
            var output: [NativeConductorUnion.SourceFact] = []
            for value in values {
                try budget.visit(1, isCancelled)
                output.append(.init(artifactID: value.artifactID, byteRange: value.byteRange))
            }
            return output
        }
        for wire in input.wires {
            try budget.visit(1, isCancelled); try budget.charge(.inputRecords)
            let id = try generated("union.source.", result.count)
            sourceOrigins[id] = wire.sourceID
            result.append(.init(sourceID: id, netName: wire.netName, layerName: wire.layerName,
                rect: try rectangle(wire.rect), sourceFacts: try facts(wire.sourceFacts, budget: &budget)))
        }
        for via in input.vias {
            for landing in via.landings {
                try budget.visit(1, isCancelled); try budget.charge(.inputRecords)
                let id = try generated("union.source.", result.count)
                sourceOrigins[id] = via.sourceID
                result.append(.init(sourceID: id, netName: via.netName, layerName: landing.layerName,
                    rect: try rectangle(landing.rect), sourceFacts: try facts(landing.sourceFacts, budget: &budget)))
            }
        }
        return result
    }

    mutating func resistanceInput(union: NativeConductorUnion, geometry: NativeRoutedPEXGeometry,
                                  isCancelled: @Sendable () -> Bool)
        throws(NativeRoutedPEXError) -> NativeSheetResistanceInput {
        var materials: [NativeSheetResistanceInput.Material] = [], cuts: [NativeSheetResistanceInput.Cut] = []
        var terminals: [NativeSheetResistanceInput.Terminal] = []
        for layer in input.layers {
            try budget.visit(1, isCancelled); try budget.charge(.inputRecords)
            materials.append(.init(layerName: layer.name, sheetOhms: layer.sheetResistanceOhmsPerSquare))
        }
        for via in input.vias {
            try budget.visit(1, isCancelled)
            var levels = Set<Int>()
            for landing in via.landings {
                try budget.visit(1, isCancelled)
                guard let layer = geometry.layers[landing.layerName] else { throw .invalidInput(reason: .layer, sourceIDs: [via.sourceID]) }
                if levels.insert(layer.level).inserted { try budget.charge(.inputRecords) }
            }
            guard levels.count == 2, let low = levels.min(), let high = levels.max(),
                  let lower = geometry.levels[low], let upper = geometry.levels[high] else {
                throw .invalidInput(reason: .cutContact, sourceIDs: [via.sourceID])
            }
            for cut in via.cuts {
                try budget.visit(1, isCancelled); try budget.charge(.inputRecords)
                let id = try generated("union.cut.", cuts.count)
                sourceOrigins[id] = via.sourceID
                cuts.append(.init(sourceID: id, netName: via.netName, lowerLayerName: lower.name,
                    upperLayerName: upper.name, rect: try rectangle(cut.rect), sourceOhms: cut.resistanceOhms))
            }
        }
        for terminal in input.terminals {
            try budget.visit(1, isCancelled); try budget.charge(.inputRecords)
            var contacts: [NativeSheetResistanceInput.Contact] = []
            for contact in terminal.contacts {
                try budget.visit(1, isCancelled); try budget.charge(.inputRecords)
                contacts.append(.init(layerName: contact.layerName, rect: try rectangle(contact.rect)))
            }
            terminals.append(.init(ref: terminal.ref, contacts: contacts))
        }
        return .init(conductorUnion: union, materials: materials, cuts: cuts, terminals: terminals)
    }

    mutating func queryWires(union: NativeConductorUnion, isCancelled: @Sendable () -> Bool)
        throws(NativeRoutedPEXError) -> [Input.Wire] {
        var result: [Input.Wire] = []
        for (index, band) in union.bands.enumerated() {
            try budget.visit(1, isCancelled); try budget.charge(.inputRecords)
            let r = band.rect, dx = Int64(r.maxX) - Int64(r.minX), dy = Int64(r.maxY) - Int64(r.minY)
            let axis: Input.Axis = dx >= dy ? .horizontal : .vertical
            let id = try generated("union.band.", index)
            var facts: [Input.SourceFact] = [], seen = Set<Input.SourceFact>()
            for contributor in band.contributorIndices {
                try budget.visit(1, isCancelled)
                for fact in union.sources[contributor].sourceFacts {
                    try budget.visit(1, isCancelled)
                    let value = Input.SourceFact(artifactID: fact.artifactID, byteRange: fact.byteRange)
                    if !seen.contains(value) {
                        try budget.charge(.inputRecords); seen.insert(value); facts.append(value)
                    }
                }
            }
            // Query geometry uses no electrical endpoint or ideal-potential assumption.
            let ref = NodeRef(netName: band.netName, nodeName: .init(id))
            result.append(.init(sourceID: id, sourceOrdinal: index, netName: band.netName, layerName: band.layerName,
                axis: axis, rect: .init(minX: Int64(r.minX), minY: Int64(r.minY), maxX: Int64(r.maxX), maxY: Int64(r.maxY)),
                sourceNode: ref, targetNode: ref, sourceFacts: facts))
        }
        return result
    }

    mutating func originalQueryReceipts(_ receipts: [NativeRoutedPEXResult.QueryReceipt], union: NativeConductorUnion,
                                        isCancelled: @Sendable () -> Bool)
        throws(NativeRoutedPEXError) -> [NativeRoutedPEXResult.QueryReceipt] {
        var identities: [String: [String]] = [:]
        for (index, band) in union.bands.enumerated() {
            let id = try generated("union.band.", index)
            var names = Set<String>()
            for contributor in band.contributorIndices {
                try budget.visit(1, isCancelled)
                guard let origin = sourceOrigins[union.sources[contributor].sourceID] else { throw .invalidInput(reason: .sourceIdentity, sourceIDs: []) }
                if names.insert(origin).inserted { try budget.charge(.inputRecords) }
            }
            try budget.visit(names.count, isCancelled); identities[id] = names.sorted()
        }
        var result: [NativeRoutedPEXResult.QueryReceipt] = []
        for value in receipts {
            try budget.visit(1, isCancelled); try budget.charge(.inputRecords)
            var names = Set<String>()
            for identity in value.sourceIDs {
                guard let origins = identities[identity] else { throw .invalidInput(reason: .sourceIdentity, sourceIDs: [identity]) }
                for origin in origins {
                    try budget.visit(1, isCancelled)
                    if names.insert(origin).inserted { try budget.charge(.inputRecords) }
                }
            }
            result.append(.init(sourceIDs: names.sorted(), context: value.context,
                requestedWidthDatabaseUnits: value.requestedWidthDatabaseUnits,
                requestedDistanceDatabaseUnits: value.requestedDistanceDatabaseUnits,
                evaluatedDistanceDatabaseUnits: value.evaluatedDistanceDatabaseUnits,
                selectedWidthMicrons: value.selectedWidthMicrons, tableSourceRange: value.tableSourceRange,
                sampleSourceRanges: value.sampleSourceRanges, effectiveLengthDatabaseUnits: value.effectiveLengthDatabaseUnits,
                couplingFarads: value.couplingFarads, fringeFarads: value.fringeFarads))
        }
        return result
    }
}
