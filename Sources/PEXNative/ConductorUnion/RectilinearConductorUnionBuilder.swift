import LayoutIR
import MaskGeometry

public struct RectilinearConductorUnionBuilder: NativeConductorUnionBuilding {
    public init() {}

    public func build(sources: [NativeConductorUnion.Source], databaseUnitsPerMicron: Int64,
                      limits: NativeConductorUnionLimits, isCancelled: @Sendable () -> Bool)
        throws(NativeConductorError) -> NativeConductorUnion {
        var accounting: any NativeConductorResourceAccounting = try NativeConductorUnionBudget(limits)
        return try build(sources: sources, databaseUnitsPerMicron: databaseUnitsPerMicron,
                         accounting: &accounting, isCancelled: isCancelled)
    }

    func build(sources: [NativeConductorUnion.Source], databaseUnitsPerMicron: Int64,
               accounting: inout any NativeConductorResourceAccounting,
               isCancelled: @Sendable () -> Bool) throws(NativeConductorError) -> NativeConductorUnion {
        do {
            return try admittedBuild(sources: sources, units: databaseUnitsPerMicron,
                                     accounting: &accounting, isCancelled: isCancelled)
        } catch let error as NativeConductorError { throw error }
        catch { throw .invalidInput(reason: "Conductor union failed: \(error)", sourceIDs: []) }
    }

    private func admittedBuild(sources: [NativeConductorUnion.Source], units: Int64,
                               accounting: inout any NativeConductorResourceAccounting,
                               isCancelled: @Sendable () -> Bool) throws -> NativeConductorUnion {
        try accounting.visit(1, isCancelled: isCancelled)
        guard units > 0, !sources.isEmpty else {
            throw NativeConductorError.invalidInput(reason: "Positive units and source geometry are required", sourceIDs: [])
        }
        try accounting.charge(.inputRecords, count: sources.count)
        var identities = Set<String>()
        for source in sources {
            try accounting.visit(1, isCancelled: isCancelled)
            for text in [source.sourceID, source.netName.value, source.layerName] {
                try accounting.charge(.stringBytes, count: text.utf8.count)
                try accounting.visit(text.utf8.count, isCancelled: isCancelled)
                guard !text.isEmpty, !text.allSatisfy(\.isWhitespace) else {
                    throw NativeConductorError.invalidInput(reason: "Blank conductor identity", sourceIDs: [source.sourceID])
                }
            }
            let r = source.rect
            guard identities.insert(source.sourceID).inserted,
                  r.minX < r.maxX, r.minY < r.maxY, !source.sourceFacts.isEmpty else {
                throw NativeConductorError.invalidInput(reason: "Duplicate identity, invalid rectangle, or missing source facts", sourceIDs: [source.sourceID])
            }
            try accounting.charge(.inputRecords, count: source.sourceFacts.count)
            for fact in source.sourceFacts {
                try accounting.visit(1, isCancelled: isCancelled)
                guard fact.artifactID.digest.algorithm == .sha256, fact.artifactID.byteCount > 0,
                      fact.byteRange.lowerBound >= 0, fact.byteRange.upperBound > fact.byteRange.lowerBound,
                      UInt64(fact.byteRange.upperBound) <= fact.artifactID.byteCount else {
                    throw NativeConductorError.invalidInput(reason: "Invalid conductor source fact", sourceIDs: [source.sourceID])
                }
            }
        }
        let ordered = try sources.sorted { a, b in
            try accounting.visit(1, isCancelled: isCancelled)
            if a.layerName != b.layerName { return a.layerName < b.layerName }
            if a.netName != b.netName { return a.netName.value < b.netName.value }
            return a.sourceID < b.sourceID
        }
        for i in ordered.indices {
            for j in ordered.indices where j > i {
                try accounting.visit(1, isCancelled: isCancelled)
                let a = ordered[i], b = ordered[j]
                if a.layerName == b.layerName, a.netName != b.netName, touches(a.rect, b.rect) {
                    throw NativeConductorError.shortCircuit(sourceIDs: [a.sourceID, b.sourceID].sorted())
                }
            }
        }

        var bands: [NativeConductorUnion.Band] = []
        var start = 0
        while start < ordered.count {
            try accounting.visit(1, isCancelled: isCancelled)
            var end = start + 1
            while end < ordered.count, ordered[end].layerName == ordered[start].layerName,
                  ordered[end].netName == ordered[start].netName {
                try accounting.visit(1, isCancelled: isCancelled); end += 1
            }
            let count = end - start
            let inputEntries = try multiplied(count, 5)
            let edgeProbes = try multiplied(count, 4)
            // Each input is exactly one four-point rectangle: deterministic lower
            // input/edge/intermediate work is admitted before constructing it.
            try accounting.visit(try multiplied(count, 10), isCancelled: isCancelled)
            try accounting.charge(.coordinateValues, count: edgeProbes)
            try accounting.charge(.unionBands, count: count)
            var polygons: [IRBoundary] = []
            polygons.reserveCapacity(count)
            for index in start..<end {
                let r = ordered[index].rect
                polygons.append(IRBoundary(layer: 0, datatype: 0, points: [
                    IRPoint(x: r.minX, y: r.minY), IRPoint(x: r.maxX, y: r.minY),
                    IRPoint(x: r.maxX, y: r.maxY), IRPoint(x: r.minX, y: r.maxY)
                ], properties: []))
            }
            let sweepCap = accounting.remaining(.workVisits)
            let outputCap = accounting.remaining(.unionBands)
            var lower = try RectilinearUnionBudget(limits: .init(maximumInputEntries: inputEntries,
                maximumEdgeProbes: edgeProbes, maximumIntermediateBands: count,
                maximumSweepWork: sweepCap, maximumOutputBands: outputCap))
            let rows: [RectilinearBand]
            do {
                rows = try Region(layer: 0, polygons: polygons).rectilinearUnionBands(
                    toPolygonIndex: 0, budget: &lower, isCancelled: isCancelled)
            } catch {
                try accounting.charge(.workVisits, count: sweepCap - lower.remainingSweepWork)
                try accounting.charge(.unionBands, count: outputCap - lower.remainingOutputBands)
                if let failure = error as? RectilinearDecompositionError {
                    switch failure {
                    case .cancelled: throw NativeConductorError.cancelled
                    case .limitExceeded(.outputBands), .limitExceeded(.intermediateBands):
                        throw NativeConductorError.limitExceeded(.unionBands)
                    case .limitExceeded: throw NativeConductorError.limitExceeded(.workVisits)
                    default: break
                    }
                }
                throw NativeConductorError.invalidInput(reason: "Owned rectangle union rejected input: \(error)", sourceIDs: [])
            }
            try accounting.charge(.workVisits, count: sweepCap - lower.remainingSweepWork)
            try accounting.charge(.unionBands, count: outputCap - lower.remainingOutputBands)
            // The owned operation merges identical adjacent sweep intervals. Its
            // bands depend on physical coverage, never source contributor sets.
            for row in rows {
                try accounting.visit(1, isCancelled: isCancelled)
                let rect = NativeConductorUnion.Rect(minX: row.minX, minY: row.minY, maxX: row.maxX, maxY: row.maxY)
                var contributors: [Int] = []
                for index in start..<end {
                    try accounting.visit(1, isCancelled: isCancelled)
                    if overlaps(rect, ordered[index].rect) {
                        try accounting.charge(.contributorIndices, count: 1); contributors.append(index)
                    }
                }
                bands.append(.init(netName: ordered[start].netName, layerName: ordered[start].layerName,
                                   rect: rect, contributorIndices: contributors))
            }
            start = end
        }
        let boundaries = try exposedBoundaries(bands, accounting: &accounting, isCancelled: isCancelled)
        try accounting.visit(1, isCancelled: isCancelled)
        return NativeConductorUnion(databaseUnitsPerMicron: units, sources: ordered, bands: bands, boundaries: boundaries)
    }

    private func exposedBoundaries(_ bands: [NativeConductorUnion.Band],
                                   accounting: inout any NativeConductorResourceAccounting,
                                   isCancelled: @Sendable () -> Bool) throws -> [NativeConductorUnion.Boundary] {
        typealias Side = NativeConductorUnion.Boundary.Side
        var result: [NativeConductorUnion.Boundary] = []
        for index in bands.indices {
            let band = bands[index], r = band.rect
            for side in [Side.minX, .maxX, .minY, .maxY] {
                try accounting.visit(1, isCancelled: isCancelled)
                let vertical = side == .minX || side == .maxX
                let coordinate = side == .minX ? r.minX : side == .maxX ? r.maxX : side == .minY ? r.minY : r.maxY
                let begin = vertical ? r.minY : r.minX, end = vertical ? r.maxY : r.maxX
                var blocked: [(Int32, Int32)] = []
                for otherIndex in bands.indices where otherIndex != index {
                    try accounting.visit(1, isCancelled: isCancelled)
                    let other = bands[otherIndex], q = other.rect
                    guard band.layerName == other.layerName, band.netName == other.netName else { continue }
                    let adjacent = side == .minX ? q.maxX == coordinate : side == .maxX ? q.minX == coordinate
                        : side == .minY ? q.maxY == coordinate : q.minY == coordinate
                    let lo = max(begin, vertical ? q.minY : q.minX), hi = min(end, vertical ? q.maxY : q.maxX)
                    if adjacent, lo < hi {
                        try accounting.charge(.coordinateValues, count: 2); blocked.append((lo, hi))
                    }
                }
                try blocked.sort { a, b in
                    try accounting.visit(1, isCancelled: isCancelled)
                    return a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
                }
                var cursor = begin
                for (lo, hi) in blocked {
                    try accounting.visit(1, isCancelled: isCancelled)
                    if cursor < lo {
                        try appendBoundary(index, band, side, coordinate, cursor, lo, result: &result, accounting: &accounting)
                    }
                    cursor = max(cursor, hi)
                }
                if cursor < end {
                    try appendBoundary(index, band, side, coordinate, cursor, end, result: &result, accounting: &accounting)
                }
            }
        }
        return result
    }

    private func appendBoundary(_ index: Int, _ band: NativeConductorUnion.Band, _ side: NativeConductorUnion.Boundary.Side,
                                _ coordinate: Int32, _ begin: Int32, _ end: Int32,
                                result: inout [NativeConductorUnion.Boundary],
                                accounting: inout any NativeConductorResourceAccounting) throws(NativeConductorError) {
        try accounting.charge(.boundarySegments, count: 1)
        try accounting.charge(.contributorIndices, count: band.contributorIndices.count)
        result.append(.init(netName: band.netName, layerName: band.layerName, side: side,
            coordinate: coordinate, begin: begin, end: end, bandIndex: index, contributorIndices: band.contributorIndices))
    }
    private func multiplied(_ a: Int, _ b: Int) throws(NativeConductorError) -> Int {
        let value = a.multipliedReportingOverflow(by: b)
        guard !value.overflow else { throw .arithmeticOverflow }; return value.partialValue
    }
    private func overlaps(_ a: NativeConductorUnion.Rect, _ b: NativeConductorUnion.Rect) -> Bool {
        max(a.minX, b.minX) < min(a.maxX, b.maxX) && max(a.minY, b.minY) < min(a.maxY, b.maxY)
    }
    private func touches(_ a: NativeConductorUnion.Rect, _ b: NativeConductorUnion.Rect) -> Bool {
        let x0 = max(a.minX, b.minX), x1 = min(a.maxX, b.maxX)
        let y0 = max(a.minY, b.minY), y1 = min(a.maxY, b.maxY)
        return (x0 < x1 && y0 <= y1) || (x0 <= x1 && y0 < y1)
    }
}
