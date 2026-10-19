import PEXCore

extension SheetResistanceCalculation {
    mutating func admitInput(work: inout SheetResistanceWork) throws(NativeSheetResistanceError) {
        for count in [input.materials.count, input.cuts.count, input.terminals.count, input.conductorUnion.bands.count] {
            try work.charge(.inputRecords, count)
        }
        for material in input.materials {
            try work.visit(); try work.identifier(material.layerName)
            guard material.sheetOhms.isFinite, material.sheetOhms > 0 else { throw .invalidInput(reason: "Invalid sheet resistance.") }
            if let previous = sheet[material.layerName], previous != material.sheetOhms {
                throw .invalidInput(reason: "Conflicting material declarations.")
            }
            sheet[material.layerName] = material.sheetOhms
        }
        guard !input.conductorUnion.bands.isEmpty else { throw .invalidInput(reason: "Empty conductor union.") }
        for band in input.conductorUnion.bands {
            try work.visit(); try work.identifier(band.layerName); try work.identifier(band.netName.value)
            guard sheet[band.layerName] != nil else { throw .invalidInput(reason: "Missing sheet material.") }
        }
        var cutIDs = Set<String>()
        for cut in input.cuts {
            try work.visit()
            for string in [cut.sourceID, cut.netName.value, cut.lowerLayerName, cut.upperLayerName] { try work.identifier(string) }
            guard cutIDs.insert(cut.sourceID).inserted, valid(cut.rect),
                  cut.lowerLayerName != cut.upperLayerName, sheet[cut.lowerLayerName] != nil,
                  sheet[cut.upperLayerName] != nil, cut.sourceOhms.isFinite, cut.sourceOhms > 0 else {
                throw .invalidInput(reason: "Invalid individual cut.")
            }
        }
        var refs = Set<NodeRef>()
        for terminal in input.terminals {
            try work.visit(); try work.identifier(terminal.ref.netName.value); try work.identifier(terminal.ref.nodeName.value)
            guard refs.insert(terminal.ref).inserted, !terminal.contacts.isEmpty else {
                throw .invalidInput(reason: "Duplicate or empty terminal.")
            }
            try work.charge(.inputRecords, terminal.contacts.count)
            for contact in terminal.contacts {
                try work.visit(); try work.identifier(contact.layerName)
                guard valid(contact.rect), sheet[contact.layerName] != nil else { throw .invalidInput(reason: "Invalid terminal contact.") }
            }
        }
    }

    mutating func makeAxes(work: inout SheetResistanceWork) throws(NativeSheetResistanceError) {
        var xs = Set<Int32>(), ys = Set<Int32>()
        func insert(_ rect: Rect, work: inout SheetResistanceWork, xs: inout Set<Int32>, ys: inout Set<Int32>)
            throws(NativeSheetResistanceError) {
            for value in [rect.minX, rect.maxX] {
                try work.visit()
                if !xs.contains(value) { try work.charge(.coordinateValues); xs.insert(value) }
            }
            for value in [rect.minY, rect.maxY] {
                try work.visit()
                if !ys.contains(value) { try work.charge(.coordinateValues); ys.insert(value) }
            }
        }
        for band in input.conductorUnion.bands { try insert(band.rect, work: &work, xs: &xs, ys: &ys) }
        for cut in input.cuts { try insert(cut.rect, work: &work, xs: &xs, ys: &ys) }
        for terminal in input.terminals {
            for contact in terminal.contacts { try insert(contact.rect, work: &work, xs: &xs, ys: &ys) }
        }
        x = try refine(xs, work: &work); y = try refine(ys, work: &work)
        try work.visit(x.count); try work.visit(y.count)
        xi = Dictionary(uniqueKeysWithValues: x.enumerated().map { ($0.element, $0.offset) })
        yi = Dictionary(uniqueKeysWithValues: y.enumerated().map { ($0.element, $0.offset) })
    }

    private func refine(_ values: Set<Int32>, work: inout SheetResistanceWork) throws(NativeSheetResistanceError) -> [Int32] {
        try work.sorting(values.count)
        let base = values.sorted()
        var result: [Int32] = []
        for (index, value) in base.enumerated() {
            try work.visit()
            result.append(value)
            guard index + 1 < base.count else { continue }
            var current = Int64(value) + Int64(span)
            while current < Int64(base[index + 1]) {
                try work.visit(); try work.charge(.coordinateValues)
                result.append(Int32(current)); current += Int64(span)
            }
        }
        return result
    }

    mutating func makeCells(work: inout SheetResistanceWork) throws(NativeSheetResistanceError) {
        for band in input.conductorUnion.bands {
            try work.visit()
            let r = band.rect
            guard let x0 = xi[r.minX], let x1 = xi[r.maxX], let y0 = yi[r.minY], let y1 = yi[r.maxY] else {
                throw .invalidInput(reason: "Invalid checked union geometry.")
            }
            for row in y0..<y1 {
                for column in x0..<x1 {
                    try work.visit()
                    let key = Key(layer: band.layerName, x: column, y: row)
                    guard indices[key] == nil else { throw .invalidInput(reason: "Checked union has overlapping bands.") }
                    try work.charge(.meshCells)
                    try work.charge(.contributorIndices, band.contributorIndices.count)
                    indices[key] = cells.count
                    cells.append(.init(key: key, net: band.netName, contributors: band.contributorIndices))
                }
            }
        }
        try work.sorting(cells.count)
        cells.sort { $0.key < $1.key }
        indices.removeAll(keepingCapacity: true)
        for (index, cell) in cells.enumerated() { try work.visit(); indices[cell.key] = index }
    }
}
