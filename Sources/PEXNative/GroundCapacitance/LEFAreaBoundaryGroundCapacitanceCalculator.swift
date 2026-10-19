import PEXCore

public struct LEFAreaBoundaryGroundCapacitanceCalculator: NativeGroundCapacitanceCalculating {
    public init() {}

    public func calculate(union: NativeConductorUnion, model: PEXRoutedGroundCapacitanceModel,
                          selection: PEXOpenRCXSourceModel.Selection, cornerID: PEXCornerID,
                          limits: NativeGroundCapacitanceLimits,
                          isCancelled: () -> Bool = { Task.isCancelled })
        throws(NativeGroundCapacitanceError) -> NativeGroundCapacitanceResult {
        var budget = try Budget(limits: limits)
        return try admittedCalculate(union: union, model: model, selection: selection,
                                     cornerID: cornerID, budget: &budget, isCancelled: isCancelled)
    }

    func calculate(union: NativeConductorUnion, model: PEXRoutedGroundCapacitanceModel,
                   selection: PEXOpenRCXSourceModel.Selection, cornerID: PEXCornerID,
                   accounting: inout any NativeConductorResourceAccounting,
                   isCancelled: @Sendable () -> Bool)
        throws(NativeGroundCapacitanceError) -> NativeGroundCapacitanceResult {
        var budget = Budget(accounting: accounting)
        defer {
            if let shared = budget.sharedAccounting { accounting = shared }
        }
        return try admittedCalculate(union: union, model: model, selection: selection,
                                     cornerID: cornerID, budget: &budget, isCancelled: isCancelled)
    }

    private func admittedCalculate(union: NativeConductorUnion, model: PEXRoutedGroundCapacitanceModel,
                                   selection: PEXOpenRCXSourceModel.Selection, cornerID: PEXCornerID,
                                   budget: inout Budget, isCancelled: () -> Bool)
        throws(NativeGroundCapacitanceError) -> NativeGroundCapacitanceResult {
        try budget.visit(isCancelled)
        guard model.selection.routingLayerNames.count == 6, model.layers.count == 6 else {
            throw .invalidInput(.layerCoverage)
        }
        for text in [model.selection.processName, model.cornerID.value] + model.selection.routingLayerNames {
            try budget.string(text.utf8.count)
        }
        do { try model.selection.validate() }
        catch { throw .invalidInput(.selection) }
        guard model.selection == selection else { throw .invalidInput(.selection) }
        guard !cornerID.value.isEmpty, model.cornerID == cornerID else { throw .invalidInput(.corner) }
        guard model.capacitanceUnitPicofarads == 1, union.databaseUnitsPerMicron > 0 else {
            throw .invalidInput(.units)
        }
        try validateRanges(model.unitSourceRanges, byteCount: selection.technologyLEFArtifactID.byteCount,
                           budget: &budget, isCancelled: isCancelled)
        var layers: [String: PEXRoutedGroundCapacitanceModel.Layer] = [:]
        for index in model.layers.indices {
            try budget.input(1); try budget.visit(isCancelled)
            let layer = model.layers[index]
            try budget.string(layer.name.utf8.count)
            guard layer.name == selection.routingLayerNames[index], layers[layer.name] == nil else {
                throw .invalidInput(.layerCoverage)
            }
            guard positive(layer.areaPicofaradsPerSquareMicron), positive(layer.edgePicofaradsPerMicron),
                  layer.thicknessMicrons.map({ positive($0) }) ?? true else {
                throw .invalidInput(.coefficient)
            }
            try validateRanges(layer.sourceRanges, byteCount: selection.technologyLEFArtifactID.byteCount,
                               budget: &budget, isCancelled: isCancelled)
            layers[layer.name] = layer
        }
        try budget.input(union.bands.count); try budget.input(union.boundaries.count)
        try budget.output(union.bands.count); try budget.output(union.boundaries.count)
        var areas: [NativeGroundCapacitanceResult.BandAreaContribution] = []
        var edges: [NativeGroundCapacitanceResult.BoundaryContribution] = []
        areas.reserveCapacity(union.bands.count); edges.reserveCapacity(union.boundaries.count)
        let scale = Double(union.databaseUnitsPerMicron)
        var total = Sum()
        for index in union.bands.indices {
            try budget.visit(isCancelled)
            let band = union.bands[index]
            guard let layer = layers[band.layerName] else { throw .invalidInput(.layerCoverage) }
            try admitContributors(band.contributorIndices, union: union, budget: &budget, isCancelled: isCancelled)
            let dx = Int64(band.rect.maxX) - Int64(band.rect.minX)
            let dy = Int64(band.rect.maxY) - Int64(band.rect.minY)
            guard dx > 0, dy > 0 else { throw .invalidInput(.geometry) }
            let area = UInt64(dx).multipliedReportingOverflow(by: UInt64(dy))
            guard !area.overflow else { throw .unrepresentableArithmetic }
            let squareMicrons = try multiply(Double(area.partialValue) / scale, 1 / scale)
            let farads = try multiply(try multiply(layer.areaPicofaradsPerSquareMicron, squareMicrons), 1e-12)
            try total.append(farads)
            areas.append(.init(bandIndex: index, farads: farads, contributorIndices: band.contributorIndices))
        }
        for index in union.boundaries.indices {
            try budget.visit(isCancelled)
            let boundary = union.boundaries[index]
            guard let layer = layers[boundary.layerName] else { throw .invalidInput(.layerCoverage) }
            try admitContributors(boundary.contributorIndices, union: union, budget: &budget, isCancelled: isCancelled)
            let length = Int64(boundary.end) - Int64(boundary.begin)
            guard length > 0 else { throw .invalidInput(.geometry) }
            let farads = try multiply(try multiply(layer.edgePicofaradsPerMicron, Double(length) / scale), 1e-12)
            try total.append(farads)
            edges.append(.init(boundaryIndex: index, farads: farads, contributorIndices: boundary.contributorIndices))
        }
        try budget.visit(isCancelled)
        return .init(union: union, model: model, bandAreaContributions: areas,
                     boundaryContributions: edges, totalFarads: try total.result(),
                     workVisitsConsumed: budget.work, inputRecordsConsumed: budget.inputs,
                     stringBytesConsumed: budget.strings, outputRecordsConsumed: budget.outputs)
    }

    private func validateRanges(_ ranges: [PEXOpenRCXSourceModel.SourceRange], byteCount: UInt64,
                                budget: inout Budget, isCancelled: () -> Bool)
        throws(NativeGroundCapacitanceError) {
        guard !ranges.isEmpty else { throw .invalidInput(.sourceRange) }
        try budget.input(ranges.count)
        for range in ranges {
            try budget.visit(isCancelled)
            guard range.lowerBound >= 0, range.upperBound > range.lowerBound,
                  UInt64(range.upperBound) <= byteCount else { throw .invalidInput(.sourceRange) }
        }
    }

    private func admitContributors(_ indices: borrowing [Int], union: borrowing NativeConductorUnion,
                                   budget: inout Budget, isCancelled: () -> Bool)
        throws(NativeGroundCapacitanceError) {
        guard !indices.isEmpty else { throw .invalidInput(.geometry) }
        try budget.input(indices.count)
        for offset in indices.indices {
            try budget.visit(isCancelled)
            let index = indices[offset]
            guard union.sources.indices.contains(index) else { throw .invalidInput(.geometry) }
        }
    }

    private func positive(_ value: Double) -> Bool { value.isFinite && value > 0 }
    private func multiply(_ a: Double, _ b: Double) throws(NativeGroundCapacitanceError) -> Double {
        let result = a * b
        guard positive(a), positive(b), positive(result) else { throw .unrepresentableArithmetic }
        return result
    }
    private struct Sum {
        var sum = 0.0, correction = 0.0
        mutating func append(_ value: Double) throws(NativeGroundCapacitanceError) {
            let next = sum + value
            guard value.isFinite, value > 0, next.isFinite else { throw .unrepresentableArithmetic }
            let remainder = abs(sum) >= abs(value) ? (sum - next) + value : (value - next) + sum
            let accumulated = correction + remainder
            guard accumulated.isFinite else { throw .unrepresentableArithmetic }
            sum = next; correction = accumulated
        }
        func result() throws(NativeGroundCapacitanceError) -> Double {
            let value = sum + correction
            guard value.isFinite, value >= 0 else { throw .unrepresentableArithmetic }
            return value
        }
    }

    private struct Budget {
        let limits: NativeGroundCapacitanceLimits
        var sharedAccounting: (any NativeConductorResourceAccounting)?
        var inputs = 0, strings = 0, outputs = 0, work = 0
        init(limits: NativeGroundCapacitanceLimits) throws(NativeGroundCapacitanceError) {
            guard [limits.maximumInputRecords, limits.maximumStringBytes,
                   limits.maximumOutputRecords, limits.maximumWorkVisits].allSatisfy({ $0 >= 0 }) else {
                throw .invalidInput(.units)
            }
            self.limits = limits
        }
        init(accounting: any NativeConductorResourceAccounting) {
            // Shared admission owns every limit; these counters only report this call's usage.
            limits = .init(maximumInputRecords: .max, maximumStringBytes: .max,
                           maximumOutputRecords: .max, maximumWorkVisits: .max)
            sharedAccounting = accounting
        }
        mutating func input(_ count: Int) throws(NativeGroundCapacitanceError) {
            guard count >= 0, count <= limits.maximumInputRecords - inputs else { throw .limitExceeded(.inputRecords) }
            try chargeShared(.inputRecords, count)
            inputs += count
        }
        mutating func string(_ count: Int) throws(NativeGroundCapacitanceError) {
            guard count >= 0, count <= limits.maximumStringBytes - strings else { throw .limitExceeded(.stringBytes) }
            try chargeShared(.stringBytes, count)
            strings += count
        }
        mutating func output(_ count: Int) throws(NativeGroundCapacitanceError) {
            guard count >= 0, count <= limits.maximumOutputRecords - outputs else { throw .limitExceeded(.outputRecords) }
            try chargeShared(.graphElements, count)
            outputs += count
        }
        mutating func visit(_ isCancelled: () -> Bool) throws(NativeGroundCapacitanceError) {
            if isCancelled() { throw .cancelled }
            guard work < limits.maximumWorkVisits else { throw .limitExceeded(.workVisits) }
            try chargeShared(.workVisits, 1)
            work += 1
        }
        private mutating func chargeShared(_ resource: NativeConductorResource, _ count: Int)
            throws(NativeGroundCapacitanceError) {
            do { try sharedAccounting?.charge(resource, count: count) }
            catch { throw .conductor(error) }
        }
    }
}
