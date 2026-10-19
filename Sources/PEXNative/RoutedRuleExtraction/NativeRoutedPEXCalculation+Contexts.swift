import PEXCore

extension NativeRoutedPEXCalculation {
    struct GSRun { let span: Geometry.Interval; let black: Bool }

    mutating func gs(_ span: Geometry.Interval, base: Int64, axis: Input.Axis, target: Input.Layer,
                     isCancelled: () -> Bool) throws(NativeRoutedPEXError) -> [GSRun] {
        let die = geometry.input.dieBounds
        let origin = axis == .horizontal ? die.minX : die.minY
        let end = axis == .horizontal ? die.maxX : die.maxY
        let baseOrigin = axis == .horizontal ? die.minY : die.minX
        let baseEnd = axis == .horizontal ? die.maxY : die.maxX
        let rx = target.preferredDirection == .horizontal ? target.defaultWidthDatabaseUnits : target.pitchDatabaseUnits
        let ry = target.preferredDirection == .horizontal ? target.pitchDatabaseUnits : target.defaultWidthDatabaseUnits
        let resolution = axis == .horizontal ? rx : ry
        let normalResolution = axis == .horizontal ? ry : rx
        let planeBaseEnd = baseOrigin + (baseEnd - baseOrigin) / normalResolution * normalResolution
        guard base >= baseOrigin, base <= planeBaseEnd, span.high >= origin, span.low <= end else { return [] }
        let low = max(span.low, origin), high = min(span.high, end)
        let row = (base - baseOrigin) / normalResolution
        let maxPixel = (end - origin) / resolution
        var black: [Geometry.Interval] = []
        for wire in geometry.wires {
            try budget.visit(1, isCancelled)
            if wire.layerName != target.name { continue }
            if geometry.roles[wire.netName] == .signal && wire.axis == axis { continue }
            let r = wire.rect
            let b0 = axis == .horizontal ? r.minY : r.minX, b1 = axis == .horizontal ? r.maxY : r.maxX
            let l0 = axis == .horizontal ? r.minX : r.minY, l1 = axis == .horizontal ? r.maxX : r.maxY
            if b1 < baseOrigin || b0 > planeBaseEnd || l1 < origin || l0 > end { continue }
            let p0 = max(0, (b0 - baseOrigin) / normalResolution)
            let p1 = min((planeBaseEnd - baseOrigin) / normalResolution, (b1 - baseOrigin) / normalResolution)
            if row < p0 || row > p1 { continue }
            let x0 = max(0, min(maxPixel, (l0 - origin) / resolution))
            let x1 = max(0, min(maxPixel, (l1 - origin) / resolution))
            black.append(.init(low: origin + x0 * resolution, high: origin + (x1 + 1) * resolution - 1))
            try budget.charge(.coordinateValues, 2)
        }
        black.sort { $0.low < $1.low }
        var union: [Geometry.Interval] = []
        for part in black {
            try budget.visit(1, isCancelled)
            if let last = union.last, part.low <= last.high + 1 {
                union[union.count - 1] = .init(low: last.low, high: max(last.high, part.high))
            } else { union.append(part) }
        }
        var result: [GSRun] = [], cursor = low
        for part in union {
            try budget.visit(1, isCancelled)
            let a = max(low, part.low), b = min(high, part.high)
            if b < a { continue }
            if cursor < a { result.append(.init(span: .init(low: cursor, high: a - 1), black: false)) }
            result.append(.init(span: .init(low: a, high: b), black: true))
            cursor = b + 1
            if cursor > high { break }
        }
        if cursor <= high { result.append(.init(span: .init(low: cursor, high: high), black: false)) }
        return result
    }

    mutating func capacitance(_ isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        for event in search.events {
            try budget.visit(1, isCancelled)
            let source = geometry.wires[event.source]
            let targetRole = event.target.map { geometry.roles[geometry.wires[$0].netName] }
            if geometry.roles[source.netName] == .reference && (event.target == nil || targetRole == .reference) { continue }
            guard let layer = geometry.layers[source.layerName] else { throw .invalidInput(reason: .layer, sourceIDs: [source.sourceID]) }
            if diagonalGroup != event.group { try prepareDiagonal(event, layer: layer, isCancelled: isCancelled) }
            var white = [event.span]
            var covered: Int64 = 0
            let upperLimit = min(7, layer.level + geometry.profile.contextDepth)
            if layer.level < 6 {
                for upper in (layer.level + 1)..<upperLimit {
                    guard let upperLayer = geometry.levels[upper] else { throw .invalidInput(reason: .layer, sourceIDs: [source.sourceID]) }
                    var upperBlack: [Geometry.Interval] = [], nextWhite: [Geometry.Interval] = []
                    for part in white {
                        let runs = try gs(part, base: Events.base(source), axis: source.axis, target: upperLayer, isCancelled: isCancelled)
                        for run in runs {
                            if run.black { upperBlack.append(run.span); covered += run.span.length }
                            else {
                                try diagonal(event, span: run.span, targetLevel: upper, isCancelled: isCancelled)
                                nextWhite.append(run.span)
                            }
                        }
                    }
                    white = nextWhite
                    var pending = upperBlack
                    let lowerLimit = max(0, layer.level - geometry.profile.contextDepth)
                    if layer.level > 1 {
                        for lower in stride(from: layer.level - 1, through: lowerLimit + 1, by: -1) {
                            guard let lowerLayer = geometry.levels[lower] else { throw .invalidInput(reason: .layer, sourceIDs: [source.sourceID]) }
                            var remainder: [Geometry.Interval] = []
                            for part in pending {
                                let runs = try gs(part, base: Events.base(source), axis: source.axis, target: lowerLayer, isCancelled: isCancelled)
                                for run in runs {
                                    if run.black {
                                        try apply(event, context: .init(metal: layer.level, kind: .overUnder, underMetal: lower, overMetal: upper),
                                            span: run.span, isCancelled: isCancelled)
                                    } else { remainder.append(run.span) }
                                }
                            }
                            pending = remainder
                            if pending.isEmpty { break }
                        }
                    }
                    for part in pending {
                        // The consumer queries the known upper plane again for its remainder.
                        for run in try gs(part, base: Events.base(source), axis: source.axis, target: upperLayer, isCancelled: isCancelled) where run.black {
                            try apply(event, context: .init(metal: layer.level, kind: .under, overMetal: upper), span: run.span, isCancelled: isCancelled)
                        }
                    }
                    if white.isEmpty { break }
                }
            }
            if layer.level > 1 {
                for lower in stride(from: layer.level - 1, through: 1, by: -1) {
                    guard let lowerLayer = geometry.levels[lower] else { throw .invalidInput(reason: .layer, sourceIDs: [source.sourceID]) }
                    var remainder: [Geometry.Interval] = []
                    for part in white {
                        for run in try gs(part, base: Events.base(source), axis: source.axis, target: lowerLayer, isCancelled: isCancelled) {
                            if run.black {
                                covered += run.span.length
                                try apply(event, context: .init(metal: layer.level, kind: .over, underMetal: lower), span: run.span, isCancelled: isCancelled)
                            } else { remainder.append(run.span) }
                        }
                    }
                    white = remainder
                    if white.isEmpty { break }
                }
            }
            guard covered >= 0, covered <= event.span.length else { throw .unrepresentableArithmetic }
            let effective = (event.gap == nil ? event.span.length : 2 * event.span.length) - covered
            if effective > 0 {
                try apply(event, context: .init(metal: layer.level, kind: .over, underMetal: 0),
                    span: event.span, effectiveLength: effective, isCancelled: isCancelled)
            }
        }
        if purpose == .legacy { try landingCapacitance(isCancelled) }
    }

    mutating func prepareDiagonal(_ event: Events.Event, layer: Input.Layer,
                                  isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        diagonalGroup = event.group; diagonalTargets.removeAll(keepingCapacity: true); diagonalCursors.removeAll(keepingCapacity: true)
        let axis = geometry.wires[event.source].axis
        let depth = geometry.profile.diagonalContextDepth
        for level in max(1, layer.level - depth)...min(6, layer.level + depth) {
            guard let targetLayer = geometry.levels[level] else { throw .invalidInput(reason: .layer, sourceIDs: []) }
            let center = Events.track(event.contextBase, targetLayer, axis, geometry.input.dieBounds)
            let low = max(0, center - Int64(geometry.profile.lateralContextTracks))
            let high = center + Int64(geometry.profile.lateralContextTracks)
            var seen = Set<Int>()
            for number in low...high {
                var list: [Int] = []
                for index in search.tracks[.init(level: level, axis: axis, number: number)] ?? [] {
                    try budget.visit(1, isCancelled)
                    if seen.insert(index).inserted { list.append(index) }
                }
                list.sort { Events.ordered(geometry.wires[$0], geometry.wires[$1]) }
                let key = DiagonalKey(level: level, track: number - center)
                diagonalTargets[key] = list; diagonalCursors[key] = 0
            }
        }
    }

    mutating func diagonal(_ event: Events.Event, span: Geometry.Interval, targetLevel: Int,
                           isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        if span.length <= 0 { return }
        if geometry.conductorUnion != nil {
            try exposedDiagonal(event, span: span, targetLevel: targetLevel, isCancelled: isCancelled)
            return
        }
        let source = geometry.wires[event.source]
        guard let sourceLayer = geometry.layers[source.layerName] else { throw .invalidInput(reason: .layer, sourceIDs: [source.sourceID]) }
        if targetLevel - sourceLayer.level > geometry.profile.diagonalContextDepth { return }
        var residual = [span]
        for track: Int64 in [0, 1, -1, 2, -2, 3, -3] {
            let key = DiagonalKey(level: targetLevel, track: track)
            let targets = diagonalTargets[key] ?? []
            var next: [Geometry.Interval] = []
            for part in residual {
                var covered = part.low
                var index = diagonalCursors[key] ?? 0
                while index < targets.count {
                    try budget.visit(1, isCancelled)
                    let target = geometry.wires[targets[index]], targetSpan = Events.span(target)
                    if targetSpan.high <= covered { index += 1; continue }
                    if targetSpan.low >= part.high { break }
                    if targetSpan.low > covered { next.append(.init(low: covered, high: min(part.high, targetSpan.low))) }
                    let overlap = Geometry.Interval(low: max(covered, targetSpan.low), high: min(part.high, targetSpan.high))
                    if overlap.length > 0 {
                        let distance = max(0, max(Events.base(target) - Events.base(source) - Events.width(source),
                                                 Events.base(source) - Events.base(target) - Events.width(target)))
                        let value = try sample(.init(metal: sourceLayer.level, kind: .diagUnder, overMetal: targetLevel),
                            width: Events.width(source), distance: distance, length: overlap.length,
                            ids: [source.sourceID, target.sourceID], isCancelled: isCancelled)
                        if source.netName == target.netName {
                            try ground(targets[index], overlap, value.fringe, isCancelled)
                        } else { try coupling(event.source, targets[index], overlap, value.fringe, isCancelled) }
                    }
                    covered = overlap.high
                    if targetSpan.high >= part.high { break }
                    index += 1
                }
                diagonalCursors[key] = index
                if covered < part.high { next.append(.init(low: covered, high: part.high)) }
            }
            residual = next
            if residual.isEmpty { break }
        }
    }

    mutating func landingCapacitance(_ isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        for (index, via) in geometry.vias.enumerated() where geometry.roles[via.netName] == .signal {
            try budget.visit(1, isCancelled)
            var selected: Input.Landing?, selectedLevel = -1
            for landing in via.landings {
                try budget.visit(1, isCancelled)
                guard let layer = geometry.layers[landing.layerName] else { throw .invalidInput(reason: .layer, sourceIDs: [via.sourceID]) }
                let length = max(landing.rect.maxX - landing.rect.minX, landing.rect.maxY - landing.rect.minY)
                let previousLength = selected.map { max($0.rect.maxX - $0.rect.minX, $0.rect.maxY - $0.rect.minY) } ?? -1
                if layer.level > selectedLevel || (layer.level == selectedLevel && length > previousLength) {
                    selected = landing; selectedLevel = layer.level
                }
            }
            guard let landing = selected, let a = geometry.nodes[via.sourceNode], let b = geometry.nodes[via.targetNode] else {
                throw .invalidInput(reason: .via, sourceIDs: [via.sourceID])
            }
            let dx = landing.rect.maxX - landing.rect.minX, dy = landing.rect.maxY - landing.rect.minY
            let value = try sample(.init(metal: selectedLevel, kind: .over, underMetal: 0), width: min(dx, dy),
                distance: nil, length: 2 * max(dx, dy), ids: [via.sourceID], isCancelled: isCancelled)
            let node = a.layerName == landing.layerName ? a.ref : b.ref
            guard a.layerName == landing.layerName || b.layerName == landing.layerName else {
                throw .invalidInput(reason: .via, sourceIDs: [via.sourceID])
            }
            viaCaps.append((index, value.fringe, node))
            try budget.charge(.queryReceipts)
            viaLandingReceipts.append(.init(sourceID: via.sourceID, selectedLayerName: landing.layerName,
                selectedRect: landing.rect, sourceFacts: landing.sourceFacts, groundCapacitanceFarads: value.fringe))
        }
    }
}
