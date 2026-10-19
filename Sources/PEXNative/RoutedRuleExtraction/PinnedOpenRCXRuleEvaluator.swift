import PEXCore

public struct PinnedOpenRCXRuleEvaluator: NativeRoutedRuleEvaluating {
    private struct PreparedTable: Sendable {
        let widthMicrons: Double
        let sourceRange: PEXOpenRCXSourceModel.SourceRange
        let points: [(distance: Int64, sample: PEXOpenRCXSourceModel.CapacitanceSample)]
    }
    public let model: PEXOpenRCXSourceModel
    public let databaseUnitsPerMicron: Int64
    private let tables: [PEXOpenRCXSourceModel.Context: PreparedTable]

    public init(model: PEXOpenRCXSourceModel, databaseUnitsPerMicron: Int64,
                maximumSourceRecords: Int = 1_000_000,
                isCancelled: () -> Bool = { Task.isCancelled }) throws(NativeRoutedRuleError) {
        guard databaseUnitsPerMicron > 0, databaseUnitsPerMicron <= Int64(UInt32.max), maximumSourceRecords > 0 else {
            throw .invalidQuery
        }
        var remaining = maximumSourceRecords
        func visit(_ count: Int = 1) throws(NativeRoutedRuleError) {
            if isCancelled() { throw .cancelled }
            guard count <= remaining else { throw .limitExceeded }
            remaining -= count
        }
        try visit(model.families.count)
        try visit(model.tables.count)
        for table in model.tables {
            try visit(table.capacitanceSamples.count)
            try visit(table.resistanceSamples.count)
        }
        do { try model.validate() } catch { throw .invalidModel(error) }
        var tables: [PEXOpenRCXSourceModel.Context: PreparedTable] = [:]
        for table in model.tables where table.context.kind != .resOver {
            var points: [(distance: Int64, sample: PEXOpenRCXSourceModel.CapacitanceSample)] = []
            points.reserveCapacity(table.capacitanceSamples.count)
            var previous: Int64?
            for sample in table.capacitanceSamples {
                if isCancelled() { throw .cancelled }
                let d = try Self.dbUnits(sample.distanceMicrons, databaseUnitsPerMicron, permitsZero: true)
                if let previous, d <= previous { throw .unrepresentableArithmetic }
                points.append((d, sample)); previous = d
            }
            _ = try Self.dbUnits(table.widthMicrons, databaseUnitsPerMicron)
            tables[table.context] = PreparedTable(widthMicrons: table.widthMicrons,
                sourceRange: table.sourceRange, points: points)
        }
        self.model = model; self.databaseUnitsPerMicron = databaseUnitsPerMicron; self.tables = tables
    }

    public func evaluate(context: PEXOpenRCXSourceModel.Context, widthDatabaseUnits: Int64,
                         distance: NativeRoutedRuleDistance, maximumWorkVisits: Int = 1_000_000,
                         isCancelled: () -> Bool = { Task.isCancelled })
        throws(NativeRoutedRuleError) -> NativeRoutedRuleEvaluation {
        guard widthDatabaseUnits > 0, widthDatabaseUnits <= Int64(UInt32.max), maximumWorkVisits > 0 else {
            throw .invalidQuery
        }
        if case .finite(let value) = distance, (value < 0 || value > Int64(UInt32.max)) { throw .invalidQuery }
        var remaining = maximumWorkVisits
        func visit() throws(NativeRoutedRuleError) {
            if isCancelled() { throw .cancelled }
            guard remaining > 0 else { throw .limitExceeded }
            remaining -= 1
        }
        try visit()
        guard context.kind != .resOver else { throw .resistanceOnlyContext }
        guard let table = tables[context] else { throw .unavailableContext }
        let points = table.points
        guard !points.isEmpty else { throw .emptyActiveTable }
        let selected: (coupling: Double, fringe: Double, resistance: Double, ranges: [PEXOpenRCXSourceModel.SourceRange], distance: Int64?)
        let first = points[0], last = points[points.count - 1]
        func values(_ p: (distance: Int64, sample: PEXOpenRCXSourceModel.CapacitanceSample),
                    at d: Int64?) -> (Double, Double, Double, [PEXOpenRCXSourceModel.SourceRange], Int64?) {
            (p.sample.couplingFemtofaradsPerNanometer, p.sample.fringeFemtofaradsPerNanometer,
             p.sample.resistanceOhmsPerNanometer, [p.sample.sourceRange], d)
        }
        switch distance {
        case .open:
            selected = values(last, at: nil)
        case .finite(let d):
            if d <= first.distance {
                selected = values(first, at: first.distance)
            } else if last.distance == 100_000 {
                guard points.count >= 2 else { throw .unrepresentableArithmetic }
                var index = points.count - 2
                if points[index].distance == 99_000 { index -= 1 }
                guard index >= 0 else { throw .unrepresentableArithmetic }
                let finite = points[index]
                if d == finite.distance {
                    selected = values(finite, at: d)
                } else if d > finite.distance {
                    guard finite.distance > 0 else { throw .unrepresentableArithmetic }
                    if Double(d) <= 2 * Double(finite.distance) {
                        guard points.count >= 3 else { throw .unrepresentableArithmetic }
                        let a = points[points.count - 3], b = points[points.count - 2]
                        let resistance = try interpolate(d, a.distance, b.distance,
                            a.sample.resistanceOhmsPerNanometer, b.sample.resistanceOhmsPerNanometer)
                        selected = (finite.sample.couplingFemtofaradsPerNanometer * Double(finite.distance) / Double(d),
                            finite.sample.fringeFemtofaradsPerNanometer, resistance,
                            [finite.sample.sourceRange, a.sample.sourceRange, b.sample.sourceRange], d)
                    } else {
                        selected = values(last, at: last.distance)
                    }
                } else {
                    selected = try interior(points, d, maximumPointIndex: index, { () throws(NativeRoutedRuleError) in try visit() })
                }
            } else if last.distance > 0 && d >= Int64(UInt32(last.distance) &- UInt32(4)) {
                selected = values(last, at: last.distance)
            } else {
                selected = try interior(points, d, { () throws(NativeRoutedRuleError) in try visit() })
            }
        }
        let nanometersPerDBU = 1000 / Double(databaseUnitsPerMicron)
        let cc = selected.coupling * nanometersPerDBU * 1e-15
        let fr = selected.fringe * nanometersPerDBU * 1e-15
        let r = selected.resistance * nanometersPerDBU
        guard cc.isFinite, fr.isFinite, r.isFinite, cc >= 0, fr >= 0, r >= 0,
              selected.coupling == 0 || cc > 0, selected.fringe == 0 || fr > 0,
              selected.resistance == 0 || r > 0 else { throw .unrepresentableArithmetic }
        return NativeRoutedRuleEvaluation(workVisitsConsumed: maximumWorkVisits - remaining, context: context, selectedWidthMicrons: table.widthMicrons,
            tableSourceRange: table.sourceRange, sampleSourceRanges: selected.ranges,
            evaluatedDistanceDatabaseUnits: selected.distance,
            couplingFaradsPerDatabaseUnit: cc, fringeFaradsPerDatabaseUnit: fr,
            resistanceOhmsPerDatabaseUnit: r)
    }

    private static func dbUnits(_ microns: Double, _ scale: Int64, permitsZero: Bool = false)
        throws(NativeRoutedRuleError) -> Int64 {
        let value = (microns * Double(scale)).rounded()
        guard value.isFinite, value >= 0, value <= Double(UInt32.max), permitsZero || value > 0 else {
            throw .unrepresentableArithmetic
        }
        return Int64(value)
    }

    private func interpolate(_ d: Int64, _ x1: Int64, _ x2: Int64, _ y1: Double, _ y2: Double)
        throws(NativeRoutedRuleError) -> Double {
        guard x2 > x1 else { throw .unrepresentableArithmetic }
        let value = y2 - (y2 - y1) / Double(x2 - x1) * Double(x2 - d)
        guard value.isFinite else { throw .unrepresentableArithmetic }
        return value
    }

    private func interior(_ points: [(distance: Int64, sample: PEXOpenRCXSourceModel.CapacitanceSample)],
                          _ distance: Int64, maximumPointIndex: Int? = nil,
                          _ visit: () throws(NativeRoutedRuleError) -> Void)
        throws(NativeRoutedRuleError) -> (Double, Double, Double, [PEXOpenRCXSourceModel.SourceRange], Int64?) {
        let bucket = distance / 4
        let high = bucket * 4 + 3
        let lastIndex = maximumPointIndex ?? (points.count - 1)
        // mapInterpolate starts at each source row, not a global multiple of four.
        // Later intervals overwrite an existing bucket, so inspect them backwards.
        if lastIndex > 0 {
            for index in stride(from: lastIndex, through: 1, by: -1) {
                try visit()
                let a = points[index - 1], b = points[index]
                let upper = min(high, b.distance)
                guard upper >= a.distance else { continue }
                let actual = a.distance + (upper - a.distance) / 4 * 4
                guard actual / 4 == bucket else { continue }
                return (try interpolate(actual, a.distance, b.distance, a.sample.couplingFemtofaradsPerNanometer, b.sample.couplingFemtofaradsPerNanometer),
                        try interpolate(actual, a.distance, b.distance, a.sample.fringeFemtofaradsPerNanometer, b.sample.fringeFemtofaradsPerNanometer),
                        try interpolate(actual, a.distance, b.distance, a.sample.resistanceOhmsPerNanometer, b.sample.resistanceOhmsPerNanometer),
                        [a.sample.sourceRange, b.sample.sourceRange], actual)
            }
        }
        let grid = bucket * 4
        if grid <= points[0].distance {
            let s = points[0].sample
            return (s.couplingFemtofaradsPerNanometer, s.fringeFemtofaradsPerNanometer,
                    s.resistanceOhmsPerNanometer, [s.sourceRange], grid)
        }
        throw .unrepresentableArithmetic
    }
}
