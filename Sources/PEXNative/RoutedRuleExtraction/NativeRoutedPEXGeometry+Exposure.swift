import PEXCore

extension NativeRoutedPEXGeometry {
    /// Pair eligibility and final cell ports share the checked physical boundary owner.
    func exposedPairSpans(source: Int, target: Int, span: Interval,
                          budget: inout NativeRoutedPEXWorkBudget, isCancelled: () -> Bool)
        throws(NativeRoutedPEXError) -> [Interval] {
        guard let union = conductorUnion, union.bands.indices.contains(source),
              union.bands.indices.contains(target), wires.indices.contains(source), wires.indices.contains(target) else {
            throw .invalidInput(reason: .sourceIdentity, sourceIDs: [])
        }
        try budget.visit(1, isCancelled)
        let a = wires[source], b = wires[target]
        guard a.axis == b.axis else { throw .invalidInput(reason: .wire, sourceIDs: [a.sourceID, b.sourceID]) }
        let a0 = NativeRoutedPEXEvents.base(a), a1 = a0 + NativeRoutedPEXEvents.width(a)
        let b0 = NativeRoutedPEXEvents.base(b), b1 = b0 + NativeRoutedPEXEvents.width(b)
        if a.layerName != b.layerName, min(a1, b1) > max(a0, b0) {
            // Projected interlayer area is physical metal, including interior metal.
            try budget.charge(.coordinateValues, 2)
            return [span]
        }
        let sourceIsLow = a0 + a1 <= b0 + b1
        let aSide: NativeConductorUnion.Boundary.Side = a.axis == .horizontal
            ? (sourceIsLow ? .maxY : .minY) : (sourceIsLow ? .maxX : .minX)
        let bSide: NativeConductorUnion.Boundary.Side = a.axis == .horizontal
            ? (sourceIsLow ? .minY : .maxY) : (sourceIsLow ? .minX : .maxX)
        let left = try exposedSpans(band: source, side: aSide, span: span, union: union,
                                    budget: &budget, isCancelled: isCancelled)
        let right = try exposedSpans(band: target, side: bSide, span: span, union: union,
                                     budget: &budget, isCancelled: isCancelled)
        var result: [Interval] = []
        for a in left {
            for b in right {
                try budget.visit(1, isCancelled)
                let low = max(a.low, b.low), high = min(a.high, b.high)
                if low < high {
                    try budget.charge(.coordinateValues, 2)
                    result.append(.init(low: low, high: high))
                }
            }
        }
        return result
    }

    private func exposedSpans(band: Int, side: NativeConductorUnion.Boundary.Side, span: Interval,
                              union: borrowing NativeConductorUnion,
                              budget: inout NativeRoutedPEXWorkBudget, isCancelled: () -> Bool)
        throws(NativeRoutedPEXError) -> [Interval] {
        var result: [Interval] = []
        for boundary in union.boundaries {
            try budget.visit(1, isCancelled)
            guard boundary.bandIndex == band, boundary.side == side else { continue }
            let low = max(span.low, Int64(boundary.begin)), high = min(span.high, Int64(boundary.end))
            if low < high {
                try budget.charge(.coordinateValues, 2)
                result.append(.init(low: low, high: high))
            }
        }
        // Each checked band's side inventory is ordered and nonoverlapping.
        return result
    }
}
