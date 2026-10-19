import PEXCore

extension SheetResistanceCalculation {
    func orderedTerminals(work: inout SheetResistanceWork) throws(NativeSheetResistanceError) -> [NativeSheetResistanceInput.Terminal] {
        try work.sorting(input.terminals.count)
        return input.terminals.sorted {
            if $0.ref.netName.value != $1.ref.netName.value { return $0.ref.netName.value < $1.ref.netName.value }
            return $0.ref.nodeName.value < $1.ref.nodeName.value
        }
    }

    func terminalCells(_ terminals: [NativeSheetResistanceInput.Terminal], physical: inout SheetResistanceComponents,
                       work: inout SheetResistanceWork) throws(NativeSheetResistanceError) -> [[Int]] {
        var result: [[Int]] = []
        for terminal in terminals {
            try work.visit()
            var selected = Set<Int>()
            for contact in terminal.contacts {
                try work.visit()
                let r = contact.rect
                for row in yi[r.minY]!..<yi[r.maxY]! {
                    for column in xi[r.minX]!..<xi[r.maxX]! {
                        try work.visit()
                        guard let index = indices[Key(layer: contact.layerName, x: column, y: row)] else { continue }
                        guard cells[index].net == terminal.ref.netName else { throw .invalidInput(reason: "Terminal contacts a foreign net.") }
                        if !selected.contains(index) { try work.charge(.inputRecords); selected.insert(index) }
                    }
                }
            }
            guard let first = selected.first else { throw .missingTerminalContact(terminal.ref) }
            let root = try physical.root(first, work: &work)
            for index in selected {
                try work.visit()
                guard try physical.root(index, work: &work) == root else { throw .disconnectedTerminal(terminal.ref) }
            }
            try work.sorting(selected.count)
            result.append(selected.sorted())
        }
        return result
    }

    func cutFragments(physical: inout SheetResistanceComponents, work: inout SheetResistanceWork)
        throws(NativeSheetResistanceError) -> [CutFragments] {
        try work.sorting(input.cuts.count)
        let cuts = input.cuts.sorted { $0.sourceID < $1.sourceID }
        var result: [CutFragments] = []
        for cut in cuts {
            try work.visit()
            let r = cut.rect
            var lower: [Int] = [], upper: [Int] = []
            for row in yi[r.minY]!..<yi[r.maxY]! {
                for column in xi[r.minX]!..<xi[r.maxX]! {
                    try work.visit()
                    guard let a = indices[Key(layer: cut.lowerLayerName, x: column, y: row)],
                          let b = indices[Key(layer: cut.upperLayerName, x: column, y: row)],
                          cells[a].net == cut.netName, cells[b].net == cut.netName else {
                        throw .incompleteCutContact(sourceID: cut.sourceID)
                    }
                    try work.charge(.inputRecords, 2)
                    lower.append(a); upper.append(b)
                    try physical.join(a, b, work: &work)
                    if let first = lower.first { try physical.join(first, a, work: &work) }
                }
            }
            result.append(.init(cut: cut, lower: lower, upper: upper))
        }
        return result
    }
}
