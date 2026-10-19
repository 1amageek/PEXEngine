import PEXCore

struct SheetResistanceCalculation {
    typealias Rect = NativeConductorUnion.Rect
    struct Key: Hashable, Comparable {
        let layer: String
        let x: Int
        let y: Int
        static func < (a: Self, b: Self) -> Bool {
            if a.layer != b.layer { return a.layer < b.layer }
            if a.y != b.y { return a.y < b.y }
            return a.x < b.x
        }
    }
    struct Occupied {
        let key: Key
        let net: NetName
        let contributors: [Int]
    }
    struct CutFragments {
        let cut: NativeSheetResistanceInput.Cut
        let lower: [Int]
        let upper: [Int]
    }
    let input: NativeSheetResistanceInput
    let span: Int32
    var x: [Int32] = [], y: [Int32] = []
    var xi: [Int32: Int] = [:], yi: [Int32: Int] = [:]
    var cells: [Occupied] = []
    var indices: [Key: Int] = [:]
    var sheet: [String: Double] = [:]

    mutating func run(work: inout SheetResistanceWork) throws(NativeSheetResistanceError) -> NativeSheetResistanceResult {
        let start = Dictionary(uniqueKeysWithValues: NativeConductorResource.allCases.map { ($0, work.accounting.remaining($0)) })
        guard span > 0 else { throw .invalidConfiguration }
        try work.visit()
        try admitInput(work: &work)
        try makeAxes(work: &work)
        try makeCells(work: &work)
        try work.visit(cells.count)
        var physical = SheetResistanceComponents(count: cells.count)
        for (i, cell) in cells.enumerated() {
            try work.visit()
            for neighbor in forward(cell.key) {
                try work.visit()
                if let j = indices[neighbor] { try physical.join(i, j, work: &work) }
            }
        }
        let fragments = try cutFragments(physical: &physical, work: &work)
        let terminals = try orderedTerminals(work: &work)
        let contacts = try terminalCells(terminals, physical: &physical, work: &work)
        var potentials = SheetResistanceComponents(count: cells.count)
        var contacted = [Bool](repeating: false, count: cells.count)
        for group in contacts {
            guard let first = group.first else { continue }
            for index in group {
                try work.visit(); contacted[index] = true
                try potentials.join(first, index, work: &work)
            }
        }
        // Touching ideal contact regions have the same potential; preserve all terminal references below.
        for (i, cell) in cells.enumerated() where contacted[i] {
            try work.visit()
            for neighbor in forward(cell.key) {
                try work.visit()
                if let j = indices[neighbor], contacted[j] { try potentials.join(i, j, work: &work) }
            }
        }
        var nodes: [NativeSheetResistanceResult.Node] = []
        var nodeForRoot: [Int: Int] = [:]
        var cellNodes: [Int] = []
        for (i, cell) in cells.enumerated() {
            try work.visit()
            let root = contacted[i] ? try potentials.root(i, work: &work) : i
            if nodeForRoot[root] == nil {
                try work.charge(.graphNodes)
                nodeForRoot[root] = nodes.count
                nodes.append(.init(kind: contacted[i] ? .contact : .sheet, netName: cell.net,
                                   layerName: contacted[i] ? nil : cell.key.layer))
            }
            cellNodes.append(nodeForRoot[root]!)
        }
        var resistors: [NativeSheetResistanceResult.Resistor] = []
        for (i, cell) in cells.enumerated() {
            try work.visit()
            for neighbor in forward(cell.key) {
                try work.visit()
                guard let j = indices[neighbor], cellNodes[i] != cellNodes[j] else { continue }
                let alongX = neighbor.x != cell.key.x
                let a = normalSpan(cell.key, alongX: alongX), b = normalSpan(neighbor, alongX: alongX)
                let face = normalSpan(cell.key, alongX: !alongX)
                let resistance = try NativeSheetResistanceOperators.sharedFace(sheetOhms: sheet[cell.key.layer]!,
                    normalSpanA: contacted[i] ? 0 : a, normalSpanB: contacted[j] ? 0 : b, faceLength: face)
                try appendResistance(cellNodes[i], cellNodes[j], resistance,
                    kind: contacted[i] || contacted[j] ? .contact : .sheet,
                    contributors: cell.contributors, otherContributors: cells[j].contributors,
                    to: &resistors, work: &work)
            }
        }
        for fragment in fragments {
            try work.visit()
            let cut = fragment.cut, cutNode = nodes.count
            try work.charge(.graphNodes)
            nodes.append(.init(kind: .cut(sourceID: cut.sourceID), netName: cut.netName, layerName: nil))
            let area = Double(Int64(cut.rect.maxX) - Int64(cut.rect.minX)) * Double(Int64(cut.rect.maxY) - Int64(cut.rect.minY))
            for indices in [fragment.lower, fragment.upper] {
                for index in indices {
                    try work.visit()
                    let key = cells[index].key
                    let fragmentArea = Double(normalSpan(key, alongX: true)) * Double(normalSpan(key, alongX: false))
                    let ohms = cut.sourceOhms / 2 * (area / fragmentArea)
                    try appendResistance(cutNode, cellNodes[index], ohms, kind: .cut(sourceID: cut.sourceID),
                        contributors: cells[index].contributors, to: &resistors, work: &work)
                }
            }
        }
        var assignments: [NativeSheetResistanceResult.TerminalAssignment] = []
        for (index, terminal) in terminals.enumerated() {
            try work.visit(); try work.charge(.graphElements)
            assignments.append(.init(ref: terminal.ref, nodeIndex: cellNodes[contacts[index][0]], cellIndices: contacts[index]))
        }
        var outputCells: [NativeSheetResistanceResult.Cell] = []
        for (index, cell) in cells.enumerated() {
            try work.visit()
            outputCells.append(.init(netName: cell.net, layerName: cell.key.layer, rect: rect(cell.key),
                                     nodeIndex: cellNodes[index], contributorIndices: cell.contributors))
        }
        try work.visit()
        let usage = Dictionary(uniqueKeysWithValues: NativeConductorResource.allCases.map {
            ($0, start[$0]! - work.accounting.remaining($0))
        })
        return .init(input: input, conductorUnion: input.conductorUnion, maximumCellSpanDatabaseUnits: span, cells: outputCells,
                     nodes: nodes, resistors: resistors, terminalAssignments: assignments, usage: usage)
    }

    func forward(_ key: Key) -> [Key] {
        [Key(layer: key.layer, x: key.x + 1, y: key.y), Key(layer: key.layer, x: key.x, y: key.y + 1)]
    }
    func rect(_ key: Key) -> Rect {
        .init(minX: x[key.x], minY: y[key.y], maxX: x[key.x + 1], maxY: y[key.y + 1])
    }
    func normalSpan(_ key: Key, alongX: Bool) -> Int64 {
        alongX ? Int64(x[key.x + 1]) - Int64(x[key.x]) : Int64(y[key.y + 1]) - Int64(y[key.y])
    }
    func valid(_ rect: Rect) -> Bool { rect.minX < rect.maxX && rect.minY < rect.maxY }

    private func appendResistance(_ a: Int, _ b: Int, _ ohms: Double,
                                  kind: NativeSheetResistanceResult.Resistor.Kind, contributors: [Int], otherContributors: [Int] = [],
                                  to result: inout [NativeSheetResistanceResult.Resistor],
                                  work: inout SheetResistanceWork) throws(NativeSheetResistanceError) {
        let checked = try NativeSheetResistanceOperators.positive(ohms)
        guard (1 / checked).isFinite else { throw .numericFailure }
        try work.charge(.graphElements)
        let (count, overflow) = contributors.count.addingReportingOverflow(otherContributors.count)
        guard !overflow else { throw .conductor(.arithmeticOverflow) }
        try work.charge(.contributorIndices, count)
        try work.sorting(count)
        let unique = Array(Set(contributors + otherContributors)).sorted()
        result.append(.init(kind: kind, nodeA: a, nodeB: b, ohms: checked, contributorIndices: unique))
    }
}
