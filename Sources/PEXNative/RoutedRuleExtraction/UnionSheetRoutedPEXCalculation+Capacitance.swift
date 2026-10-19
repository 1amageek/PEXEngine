import PEXCore

extension UnionSheetRoutedPEXCalculation {
    struct WeightedCells {
        let a: Int
        let b: Int?
        let weight: UInt64
        let begin: Int64?
        let end: Int64?
    }
    struct CellPort {
        let cell: Int?
        let begin: Int64, end: Int64
        let normalBegin: Int64, normalEnd: Int64
    }
    struct AllocatedScalar {
        let partIndex: Int
        let farads: Double
    }
    struct PositiveSum {
        var sum = 0.0, correction = 0.0
        mutating func add(_ value: Double) throws(NativeRoutedPEXError) {
            guard value.isFinite, value >= 0 else { throw .unrepresentableArithmetic }
            let next = sum + value
            let residual = abs(sum) >= abs(value) ? (sum - next) + value : (value - next) + sum
            correction += residual; sum = next
            guard sum.isFinite, correction.isFinite else { throw .unrepresentableArithmetic }
        }
        var value: Double { sum + correction }
    }

    mutating func attachGround(_ ground: NativeGroundCapacitanceResult, sheet: NativeSheetResistanceResult,
                               graph: inout UnionSheetRoutedPEXGraph, geometry: NativeRoutedPEXGeometry,
                               isCancelled: @Sendable () -> Bool) throws(NativeRoutedPEXError) {
        for contribution in ground.bandAreaContributions {
            try budget.visit(1, isCancelled)
            let band = ground.union.bands[contribution.bandIndex]
            if geometry.roles[band.netName] == .reference { continue }
            var parts: [WeightedCells] = []
            for (index, cell) in sheet.cells.enumerated() {
                try budget.visit(1, isCancelled)
                if cell.netName != band.netName || cell.layerName != band.layerName { continue }
                let amount = try intersectionArea(cell.rect, band.rect)
                if amount > 0 {
                    try budget.charge(.inputRecords)
                    parts.append(.init(a: index, b: nil, weight: amount, begin: nil, end: nil))
                }
            }
            try emitParts(parts, farads: contribution.farads, expectedWeight: try area(band.rect),
                kind: .groundArea, bandIndex: contribution.bandIndex, boundaryIndex: nil, queryIndex: nil,
                sheet: sheet, graph: &graph, isCancelled: isCancelled)
        }
        for contribution in ground.boundaryContributions {
            try budget.visit(1, isCancelled)
            let edge = ground.union.boundaries[contribution.boundaryIndex]
            if geometry.roles[edge.netName] == .reference { continue }
            var parts: [WeightedCells] = []
            for (index, cell) in sheet.cells.enumerated() {
                try budget.visit(1, isCancelled)
                if cell.netName != edge.netName || cell.layerName != edge.layerName { continue }
                guard face(cell.rect, side: edge.side) == edge.coordinate else { continue }
                let vertical = edge.side == .minX || edge.side == .maxX
                let lo = max(Int64(edge.begin), vertical ? Int64(cell.rect.minY) : Int64(cell.rect.minX))
                let hi = min(Int64(edge.end), vertical ? Int64(cell.rect.maxY) : Int64(cell.rect.maxX))
                if hi > lo {
                    try budget.charge(.inputRecords)
                    parts.append(.init(a: index, b: nil, weight: UInt64(hi - lo), begin: lo, end: hi))
                }
            }
            try emitParts(parts, farads: contribution.farads, expectedWeight: UInt64(Int64(edge.end) - Int64(edge.begin)),
                kind: .groundBoundary, bandIndex: edge.bandIndex, boundaryIndex: contribution.boundaryIndex,
                queryIndex: nil, sheet: sheet, graph: &graph, isCancelled: isCancelled)
        }
    }

    mutating func attachCoupling(_ queries: NativeRoutedPEXCalculation, union: NativeConductorUnion,
                                 sheet: NativeSheetResistanceResult, graph: inout UnionSheetRoutedPEXGraph,
                                 isCancelled: @Sendable () -> Bool) throws(NativeRoutedPEXError) {
        for cap in queries.caps {
            try budget.visit(1, isCancelled)
            guard cap.farads.isFinite, cap.farads > 0, let other = cap.b ?? cap.reference,
                  union.bands.indices.contains(cap.a), union.bands.indices.contains(other),
                  queries.queryReceipts.indices.contains(cap.queryReceiptIndex) else { throw .unrepresentableArithmetic }
            let a = union.bands[cap.a], b = union.bands[other]
            let axis = queries.geometry.wires[cap.a].axis
            guard queries.geometry.wires[other].axis == axis, a.netName != b.netName else {
                throw .unsupportedNumericalLaw(reason: "A coupling operator lacks distinct source-bound parallel ports")
            }
            let diagonal = a.layerName != b.layerName
            let aNormal = normal(a.rect, axis), bNormal = normal(b.rect, axis)
            let overlapLow = max(aNormal.0, bNormal.0), overlapHigh = min(aNormal.1, bNormal.1)
            let areaPorts = diagonal && overlapHigh > overlapLow
            let high = aNormal.0 + aNormal.1 <= bNormal.0 + bNormal.1
            let aSide: NativeConductorUnion.Boundary.Side = axis == .horizontal
                ? (high ? .maxY : .minY) : (high ? .maxX : .minX)
            let bSide: NativeConductorUnion.Boundary.Side = axis == .horizontal
                ? (high ? .minY : .maxY) : (high ? .minX : .maxX)
            let left = try ports(bandIndex: cap.a, union: union, sheet: sheet, axis: axis,
                side: areaPorts ? nil : aSide, span: cap.span,
                normalWindow: areaPorts ? (overlapLow, overlapHigh) : nil,
                reference: false, isCancelled: isCancelled)
            let right = try ports(bandIndex: other, union: union, sheet: sheet, axis: axis,
                side: areaPorts ? nil : bSide, span: cap.span,
                normalWindow: areaPorts ? (overlapLow, overlapHigh) : nil,
                reference: cap.reference != nil, isCancelled: isCancelled)
            var parts: [WeightedCells] = []
            for x in left {
                for y in right {
                    try budget.visit(1, isCancelled)
                    let lo = max(x.begin, y.begin), hi = min(x.end, y.end)
                    if hi <= lo { continue }
                    let cross = areaPorts ? min(x.normalEnd, y.normalEnd) - max(x.normalBegin, y.normalBegin) : 1
                    if cross <= 0 { continue }
                    guard let cellA = x.cell else { throw .unrepresentableArithmetic }
                    let amount = UInt64(hi - lo).multipliedReportingOverflow(by: UInt64(cross))
                    guard !amount.overflow else { throw .unrepresentableArithmetic }
                    try budget.charge(.inputRecords)
                    parts.append(.init(a: cellA, b: y.cell, weight: amount.partialValue, begin: lo, end: hi))
                }
            }
            let expected = UInt64(cap.span.length).multipliedReportingOverflow(by: UInt64(areaPorts ? overlapHigh - overlapLow : 1))
            guard !expected.overflow else { throw .unrepresentableArithmetic }
            try emitParts(parts, farads: cap.farads, expectedWeight: expected.partialValue,
                kind: cap.reference != nil ? .referenceCoupling : diagonal ? .diagonalCoupling : .lateralCoupling,
                bandIndex: cap.a, otherBandIndex: other, boundaryIndex: nil, queryIndex: cap.queryReceiptIndex,
                sheet: sheet, graph: &graph, isCancelled: isCancelled)
        }
    }

    mutating func ports(bandIndex: Int, union: NativeConductorUnion, sheet: NativeSheetResistanceResult,
                        axis: Input.Axis, side: NativeConductorUnion.Boundary.Side?,
                        span: NativeRoutedPEXGeometry.Interval, normalWindow: (Int64, Int64)?,
                        reference: Bool, isCancelled: @Sendable () -> Bool)
        throws(NativeRoutedPEXError) -> [CellPort] {
        let band = union.bands[bandIndex]
        var result: [CellPort] = []
        if reference {
            if let window = normalWindow {
                try budget.charge(.inputRecords)
                result.append(.init(cell: nil, begin: span.low, end: span.high,
                                    normalBegin: window.0, normalEnd: window.1))
            } else if let side {
                for edge in union.boundaries where edge.bandIndex == bandIndex && edge.side == side {
                    try budget.visit(1, isCancelled)
                    let lo = max(Int64(edge.begin), span.low), hi = min(Int64(edge.end), span.high)
                    if lo < hi {
                        try budget.charge(.inputRecords)
                        result.append(.init(cell: nil, begin: lo, end: hi, normalBegin: 0, normalEnd: 1))
                    }
                }
            }
            return result
        }
        for (index, cell) in sheet.cells.enumerated() {
            try budget.visit(1, isCancelled)
            if cell.netName != band.netName || cell.layerName != band.layerName { continue }
            if try intersectionArea(cell.rect, band.rect) == 0 { continue }
            let along = longitudinal(cell.rect, axis), across = normal(cell.rect, axis)
            let lo = max(along.0, span.low), hi = min(along.1, span.high)
            if lo >= hi { continue }
            if let window = normalWindow {
                let low = max(across.0, window.0), high = min(across.1, window.1)
                if low < high {
                    try budget.charge(.inputRecords)
                    result.append(.init(cell: index, begin: lo, end: hi, normalBegin: low, normalEnd: high))
                }
            } else if let side, face(cell.rect, side: side) == face(band.rect, side: side) {
                for edge in union.boundaries where edge.bandIndex == bandIndex && edge.side == side {
                    try budget.visit(1, isCancelled)
                    let low = max(lo, Int64(edge.begin)), high = min(hi, Int64(edge.end))
                    if low < high {
                        try budget.charge(.inputRecords)
                        result.append(.init(cell: index, begin: low, end: high, normalBegin: 0, normalEnd: 1))
                    }
                }
            }
        }
        return result
    }

    mutating func emitParts(_ parts: [WeightedCells], farads: Double, expectedWeight: UInt64,
                            kind: NativeUnionSheetPEXEvidence.Attachment.Kind, bandIndex: Int?, otherBandIndex: Int? = nil, boundaryIndex: Int?,
                            queryIndex: Int?, sheet: NativeSheetResistanceResult, graph: inout UnionSheetRoutedPEXGraph,
                            isCancelled: @Sendable () -> Bool) throws(NativeRoutedPEXError) {
        let allocation = try apportion(parts, farads: farads, expectedWeight: expectedWeight, isCancelled: isCancelled)
        for scalar in allocation {
            try budget.visit(1, isCancelled)
            let part = parts[scalar.partIndex]
            try budget.charge(.graphElements)
            let id = try graph.appendCapacitance(a: sheet.cells[part.a].nodeIndex,
                b: part.b.map { sheet.cells[$0].nodeIndex }, farads: scalar.farads, budget: &budget, isCancelled: isCancelled)
            attachments.append(.init(kind: kind, elementID: id, bandIndex: bandIndex, otherBandIndex: otherBandIndex, boundaryIndex: boundaryIndex,
                queryReceiptIndex: queryIndex, cellA: part.a, cellB: part.b, farads: scalar.farads,
                longitudinalBegin: part.begin, longitudinalEnd: part.end))
        }
    }

    /// The final port can use two positive parallel scalars to retain a sub-ULP remainder.
    /// The checked compensated sum is the original scalar, with no epsilon or omitted share.
    mutating func apportion(_ parts: [WeightedCells], farads: Double, expectedWeight: UInt64,
                            isCancelled: @Sendable () -> Bool)
        throws(NativeRoutedPEXError) -> [AllocatedScalar] {
        try budget.visit(1, isCancelled)
        guard farads.isFinite, farads > 0, !parts.isEmpty, expectedWeight > 0 else { throw .unrepresentableArithmetic }
        var weight: UInt64 = 0
        var pivot = 0
        for (index, part) in parts.enumerated() {
            try budget.visit(1, isCancelled)
            let next = weight.addingReportingOverflow(part.weight)
            guard !next.overflow, part.weight > 0 else { throw .unrepresentableArithmetic }; weight = next.partialValue
            if part.weight > parts[pivot].weight { pivot = index }
        }
        guard weight == expectedWeight else {
            throw .unsupportedNumericalLaw(reason: "The numerical operator lacks complete source-bound spatial port coverage")
        }
        var emitted = PositiveSum()
        var result: [AllocatedScalar] = []
        for index in parts.indices where index != pivot {
            try budget.visit(1, isCancelled)
            let value = farads * (Double(parts[index].weight) / Double(weight))
            guard value.isFinite, value > 0 else { throw .unrepresentableArithmetic }
            try emitted.add(value)
            try budget.charge(.inputRecords)
            result.append(.init(partIndex: index, farads: value))
        }
        // Keep both components: subtracting the rounded `emitted.value` loses
        // exactly the low component needed by the actual 4e-17 F source fixture.
        var high = (farads - emitted.sum) - emitted.correction
        while true {
            try budget.visit(1, isCancelled)
            guard high.isFinite, high > 0 else { throw .unrepresentableArithmetic }
            var checked = emitted
            try checked.add(high)
            let tail = (farads - checked.sum) - checked.correction
            guard tail.isFinite else { throw .unrepresentableArithmetic }
            if tail < 0 {
                let lower = high.nextDown
                guard lower > 0, lower < high else { throw .unrepresentableArithmetic }
                high = lower
                continue
            }
            try budget.charge(.inputRecords)
            result.append(.init(partIndex: pivot, farads: high))
            if tail > 0 {
                try checked.add(tail)
                try budget.charge(.inputRecords)
                result.append(.init(partIndex: pivot, farads: tail))
            }
            guard checked.value == farads else { throw .unrepresentableArithmetic }
            return result
        }
    }

    func face(_ rect: Rect, side: NativeConductorUnion.Boundary.Side) -> Int32 {
        switch side { case .minX: rect.minX; case .maxX: rect.maxX; case .minY: rect.minY; case .maxY: rect.maxY }
    }
    func normal(_ rect: Rect, _ axis: Input.Axis) -> (Int64, Int64) {
        axis == .horizontal ? (Int64(rect.minY), Int64(rect.maxY)) : (Int64(rect.minX), Int64(rect.maxX))
    }
    func longitudinal(_ rect: Rect, _ axis: Input.Axis) -> (Int64, Int64) {
        axis == .horizontal ? (Int64(rect.minX), Int64(rect.maxX)) : (Int64(rect.minY), Int64(rect.maxY))
    }
    func area(_ rect: Rect) throws(NativeRoutedPEXError) -> UInt64 {
        let dx = Int64(rect.maxX) - Int64(rect.minX), dy = Int64(rect.maxY) - Int64(rect.minY)
        guard dx > 0, dy > 0 else { throw .unrepresentableArithmetic }
        let result = UInt64(dx).multipliedReportingOverflow(by: UInt64(dy))
        guard !result.overflow else { throw .unrepresentableArithmetic }; return result.partialValue
    }
    func intersectionArea(_ a: Rect, _ b: Rect) throws(NativeRoutedPEXError) -> UInt64 {
        let x = Int64(min(a.maxX, b.maxX)) - Int64(max(a.minX, b.minX))
        let y = Int64(min(a.maxY, b.maxY)) - Int64(max(a.minY, b.minY))
        if x <= 0 || y <= 0 { return 0 }
        let result = UInt64(x).multipliedReportingOverflow(by: UInt64(y))
        guard !result.overflow else { throw .unrepresentableArithmetic }; return result.partialValue
    }
}
