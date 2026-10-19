import PEXCore

extension NativeRoutedPEXCalculation {
    /// A hidden partition face cannot consume a later exposed target's interval.
    mutating func exposedDiagonal(_ event: Events.Event, span: Geometry.Interval, targetLevel: Int,
                                  isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        let source = geometry.wires[event.source]
        guard let layer = geometry.layers[source.layerName] else {
            throw .invalidInput(reason: .layer, sourceIDs: [source.sourceID])
        }
        if targetLevel - layer.level > geometry.profile.diagonalContextDepth { return }
        try budget.charge(.coordinateValues, 2)
        var residual = [span]
        for track: Int64 in [0, 1, -1, 2, -2, 3, -3] {
            try budget.visit(1, isCancelled)
            let key = DiagonalKey(level: targetLevel, track: track)
            let targets = diagonalTargets[key] ?? []
            var first = diagonalCursors[key] ?? 0
            // Target spans overlap. Only an expired prefix is safe to retire;
            // eligibility of an interior interval does not retire the rectangle.
            while first < targets.count {
                try budget.visit(1, isCancelled)
                if Events.span(geometry.wires[targets[first]]).high > span.low { break }
                first += 1
            }
            diagonalCursors[key] = first
            var candidate = first
            while candidate < targets.count && !residual.isEmpty {
                try budget.visit(1, isCancelled)
                let targetIndex = targets[candidate], target = geometry.wires[targetIndex]
                let targetSpan = Events.span(target)
                if targetSpan.low >= span.high { break }
                var next: [Geometry.Interval] = []
                for part in residual {
                    try budget.visit(1, isCancelled)
                    let low = max(part.low, targetSpan.low), high = min(part.high, targetSpan.high)
                    if low >= high {
                        try budget.charge(.coordinateValues, 2)
                        next.append(part)
                        continue
                    }
                    let eligible = try geometry.exposedPairSpans(source: event.source, target: targetIndex,
                        span: .init(low: low, high: high), budget: &budget, isCancelled: isCancelled)
                    var cursor = part.low
                    for interval in eligible {
                        try budget.visit(1, isCancelled)
                        if cursor < interval.low {
                            try budget.charge(.coordinateValues, 2)
                            next.append(.init(low: cursor, high: interval.low))
                        }
                        let distance = max(0, max(Events.base(target) - Events.base(source) - Events.width(source),
                                                 Events.base(source) - Events.base(target) - Events.width(target)))
                        let value = try sample(.init(metal: layer.level, kind: .diagUnder, overMetal: targetLevel),
                            width: Events.width(source), distance: distance, length: interval.length,
                            ids: [source.sourceID, target.sourceID], isCancelled: isCancelled)
                        if source.netName == target.netName {
                            try ground(targetIndex, interval, value.fringe, isCancelled)
                        } else {
                            try coupling(event.source, targetIndex, interval, value.fringe, isCancelled)
                        }
                        cursor = interval.high
                    }
                    if cursor < part.high {
                        try budget.charge(.coordinateValues, 2)
                        next.append(.init(low: cursor, high: part.high))
                    }
                }
                residual = next
                candidate += 1
            }
            if residual.isEmpty { break }
        }
    }
}
