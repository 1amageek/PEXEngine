import PEXCore

struct NativeRoutedPEXEvents {
    typealias Geometry = NativeRoutedPEXGeometry
    typealias Input = NativeRoutedPEXInput
    struct TrackKey: Hashable { let level: Int; let axis: Input.Axis; let number: Int64 }
    struct Event {
        let source: Int
        let target: Int?
        let span: Geometry.Interval
        let gap: Int64?
        let group: Int
        let contextBase: Int64
    }
    let tracks: [TrackKey: [Int]]
    let events: [Event]

    init(geometry g: Geometry, budget: inout NativeRoutedPEXWorkBudget,
         isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        var tracks: [TrackKey: [Int]] = [:]
        for (index, wire) in g.wires.enumerated() {
            try budget.visit(1, isCancelled)
            guard let layer = g.layers[wire.layerName] else { throw .invalidInput(reason: .layer, sourceIDs: [wire.sourceID]) }
            let lo = Self.track(Self.base(wire), layer, wire.axis, g.input.dieBounds)
            let hi = Self.track(Self.base(wire) + Self.width(wire), layer, wire.axis, g.input.dieBounds)
            for n in lo...hi {
                try budget.visit(1, isCancelled); try budget.charge(.trackEntries)
                tracks[.init(level: layer.level, axis: wire.axis, number: n), default: []].append(index)
            }
        }
        for key in Array(tracks.keys) {
            tracks[key]?.sort {
                let a = g.wires[$0], b = g.wires[$1]
                if Self.base(a) != Self.base(b) { return Self.base(a) < Self.base(b) }
                return Self.ordered(a, b)
            }
        }
        var events: [Event] = [], group = 0
        func emit(_ source: Int, _ target: Int?, _ span: Geometry.Interval, _ gap: Int64?, _ base: Int64) throws(NativeRoutedPEXError) {
            guard span.length > 0 else { return }
            try budget.visit(1, isCancelled); try budget.charge(.coordinateValues, 2)
            events.append(.init(source: source, target: target, span: span, gap: gap, group: group, contextBase: base))
        }
        for axis in [Input.Axis.vertical, .horizontal] {
            for level in 1...6 {
                guard let layer = g.levels[level] else { throw .invalidInput(reason: .layer, sourceIDs: []) }
                let keys = tracks.keys.filter { $0.axis == axis && $0.level == level }.sorted { $0.number < $1.number }
                for key in keys {
                    try budget.visit(1, isCancelled)
                    guard let indices = tracks[key], !indices.isEmpty else { continue }
                    let origin = axis == .horizontal ? layer.searchOriginY : layer.searchOriginX
                    var contextBase = Int64.max
                    for index in indices {
                        try budget.visit(1, isCancelled)
                        let wireBase = Self.base(g.wires[index])
                        let firstTrack = Self.track(wireBase, layer, axis, g.input.dieBounds)
                        let placedBase = firstTrack == key.number ? wireBase : origin + key.number * layer.pitchDatabaseUnits
                        contextBase = min(contextBase, placedBase)
                    }
                    var bases: [Int64] = [], lastBase: Int64?
                    for index in indices {
                        let base = Self.base(g.wires[index])
                        if base != lastBase { bases.append(base); lastBase = base }
                    }
                    for subBase in bases {
                        let sources = indices.filter { Self.base(g.wires[$0]) == subBase }
                        for high in [true, false] {
                            // The pinned Track callback resets diagonal cursors per pass.
                            group += 1
                            for (sourcePosition, source) in sources.enumerated() {
                                try budget.visit(1, isCancelled)
                                let wire = g.wires[source]
                                let ownTrack = Self.track(Self.base(wire) + (high ? Self.width(wire) : 0), layer, axis, g.input.dieBounds)
                                if ownTrack != key.number { continue }
                                var span = Self.span(wire)
                                if sourcePosition > 0 {
                                    let previous = g.wires[sources[sourcePosition - 1]]
                                    if Self.base(previous) + Self.width(previous) > Self.base(wire) + Self.width(wire) {
                                        span = .init(low: max(span.low, Self.span(previous).high), high: span.high)
                                    }
                                }
                                if sourcePosition + 1 < sources.count {
                                    let next = g.wires[sources[sourcePosition + 1]]
                                    if Self.base(next) + Self.width(next) > Self.base(wire) + Self.width(wire) {
                                        span = .init(low: span.low, high: min(span.high, Self.span(next).low))
                                    }
                                }
                                if span.length <= 0 { continue }
                                var remaining = [span]
                                for delta in 0...g.profile.lateralContextTracks {
                                    let number = key.number + (high ? Int64(delta) : -Int64(delta))
                                    if number < 0 { break }
                                    let candidates = tracks[.init(level: level, axis: axis, number: number)] ?? []
                                    let targetBases = Array(Set(candidates.map { Self.base(g.wires[$0]) })).sorted { high ? $0 < $1 : $0 > $1 }
                                    for targetBase in targetBases {
                                        if delta == 0 && (high ? targetBase <= subBase : targetBase >= subBase) { continue }
                                        for target in candidates where Self.base(g.wires[target]) == targetBase {
                                            try budget.visit(1, isCancelled)
                                            if target == source { continue }
                                            let other = g.wires[target]
                                            let lower = high ? wire : other, upper = high ? other : wire
                                            let gap = Self.base(upper) - Self.base(lower) - Self.width(lower)
                                            let threshold = layer.pitchDatabaseUnits * Int64(g.profile.lateralContextTracks)
                                            if gap >= threshold { continue }
                                            let targetSpan = Self.span(other)
                                            var nextRemaining: [Geometry.Interval] = []
                                            for part in remaining {
                                                try budget.visit(1, isCancelled)
                                                let low = max(part.low, targetSpan.low), hi = min(part.high, targetSpan.high)
                                                if g.conductorUnion != nil {
                                                    if hi <= low {
                                                        try budget.charge(.coordinateValues, 2)
                                                        nextRemaining.append(part)
                                                        continue
                                                    }
                                                    let eligible = try g.exposedPairSpans(source: source, target: target,
                                                        span: .init(low: low, high: hi), budget: &budget, isCancelled: isCancelled)
                                                    var cursor = part.low
                                                    for interval in eligible {
                                                        try budget.visit(1, isCancelled)
                                                        if cursor < interval.low {
                                                            try budget.charge(.coordinateValues, 2)
                                                            nextRemaining.append(.init(low: cursor, high: interval.low))
                                                        }
                                                        if high && gap > 0 { try emit(source, target, interval, gap, contextBase) }
                                                        cursor = interval.high
                                                    }
                                                    if cursor < part.high {
                                                        try budget.charge(.coordinateValues, 2)
                                                        nextRemaining.append(.init(low: cursor, high: part.high))
                                                    }
                                                    continue
                                                }
                                                if hi <= low { nextRemaining.append(part); continue }
                                                if part.low < low { nextRemaining.append(.init(low: part.low, high: low)) }
                                                if hi < part.high { nextRemaining.append(.init(low: hi, high: part.high)) }
                                                // Reverse all-net traversal consumes visibility but emits no pair.
                                                if high && gap > 0 { try emit(source, target, .init(low: low, high: hi), gap, contextBase) }
                                            }
                                            remaining = nextRemaining
                                            if remaining.isEmpty { break }
                                        }
                                        if remaining.isEmpty { break }
                                    }
                                    if remaining.isEmpty { break }
                                }
                                for part in remaining { try emit(source, nil, part, nil, contextBase) }
                            }
                        }
                    }
                }
            }
        }
        self.tracks = tracks; self.events = events
    }
    static func base(_ w: Input.Wire) -> Int64 { w.axis == .horizontal ? w.rect.minY : w.rect.minX }
    static func width(_ w: Input.Wire) -> Int64 { w.axis == .horizontal ? w.rect.maxY - w.rect.minY : w.rect.maxX - w.rect.minX }
    static func span(_ w: Input.Wire) -> Geometry.Interval {
        w.axis == .horizontal ? .init(low: w.rect.minX, high: w.rect.maxX) : .init(low: w.rect.minY, high: w.rect.maxY)
    }
    static func ordered(_ a: Input.Wire, _ b: Input.Wire) -> Bool {
        if span(a).low != span(b).low { return span(a).low < span(b).low }
        if base(a) != base(b) { return base(a) < base(b) }
        if span(a).length != span(b).length { return span(a).length < span(b).length }
        if width(a) != width(b) { return width(a) < width(b) }
        return a.sourceOrdinal < b.sourceOrdinal
    }
    static func track(_ coordinate: Int64, _ layer: Input.Layer, _ axis: Input.Axis, _ die: Input.Rect) -> Int64 {
        let origin = axis == .horizontal ? layer.searchOriginY : layer.searchOriginX
        let maximum = axis == .horizontal ? die.maxY : die.maxX
        let count = max(1, (maximum - origin) / layer.pitchDatabaseUnits + 1)
        return max(0, min((coordinate - origin) / layer.pitchDatabaseUnits, count - 1))
    }
}
