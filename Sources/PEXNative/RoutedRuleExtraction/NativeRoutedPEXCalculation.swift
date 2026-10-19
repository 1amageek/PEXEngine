import PEXCore

struct NativeRoutedPEXCalculation {
    enum Purpose { case legacy, canonicalUnionCoupling }
    typealias Geometry = NativeRoutedPEXGeometry
    typealias Input = NativeRoutedPEXInput
    typealias Events = NativeRoutedPEXEvents
    struct Cap {
        let a: Int
        let b: Int?
        let span: Geometry.Interval
        let farads: Double
        let reference: Int?
        let queryReceiptIndex: Int
    }
    struct DiagonalKey: Hashable { let level: Int; let track: Int64 }
    let geometry: Geometry
    let search: Events
    let rules: PinnedOpenRCXRuleEvaluator
    var budget: NativeRoutedPEXWorkBudget
    var caps: [Cap] = []
    var queryReceipts: [NativeRoutedPEXResult.QueryReceipt] = []
    var viaLandingReceipts: [NativeRoutedPEXResult.ViaLandingReceipt] = []
    var viaCaps: [(via: Int, farads: Double, node: NodeRef)] = []
    var diagonalGroup = -1
    var diagonalTargets: [DiagonalKey: [Int]] = [:]
    var diagonalCursors: [DiagonalKey: Int] = [:]
    let purpose: Purpose

    init(input: Input, model: PEXOpenRCXSourceModel, limits: NativeRoutedPEXLimits,
         isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        var budget = try NativeRoutedPEXWorkBudget(limits)
        try budget.charge(.sourceRecords, model.families.count); try budget.visit(model.families.count, isCancelled)
        try budget.charge(.sourceRecords, model.tables.count); try budget.visit(model.tables.count, isCancelled)
        for table in model.tables {
            try budget.charge(.sourceRecords, table.capacitanceSamples.count); try budget.visit(table.capacitanceSamples.count, isCancelled)
            try budget.charge(.sourceRecords, table.resistanceSamples.count); try budget.visit(table.resistanceSamples.count, isCancelled)
        }
        let geometry = try Geometry(input: input, model: model, budget: &budget, isCancelled: isCancelled)
        let search = try Events(geometry: geometry, budget: &budget, isCancelled: isCancelled)
        let rules: PinnedOpenRCXRuleEvaluator
        do { rules = try .init(model: model, databaseUnitsPerMicron: input.databaseUnitsPerMicron,
            maximumSourceRecords: limits.maximumSourceRecords, isCancelled: isCancelled) }
        catch { throw .sourceModel(error) }
        self.geometry = geometry; self.search = search; self.rules = rules; self.budget = budget; purpose = .legacy
    }

    init(geometry: Geometry, model: PEXOpenRCXSourceModel, budget: inout NativeRoutedPEXWorkBudget,
         isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        var work = budget
        defer { budget = work }
        try work.charge(.sourceRecords, model.families.count); try work.visit(model.families.count, isCancelled)
        try work.charge(.sourceRecords, model.tables.count); try work.visit(model.tables.count, isCancelled)
        for table in model.tables {
            try work.charge(.sourceRecords, table.capacitanceSamples.count); try work.visit(table.capacitanceSamples.count, isCancelled)
            try work.charge(.sourceRecords, table.resistanceSamples.count); try work.visit(table.resistanceSamples.count, isCancelled)
        }
        let search = try Events(geometry: geometry, budget: &work, isCancelled: isCancelled)
        let rules: PinnedOpenRCXRuleEvaluator
        do { rules = try .init(model: model, databaseUnitsPerMicron: geometry.input.databaseUnitsPerMicron,
            maximumSourceRecords: work.limits.maximumSourceRecords, isCancelled: isCancelled) }
        catch { throw .sourceModel(error) }
        self.geometry = geometry; self.search = search; self.rules = rules; self.budget = work
        purpose = .canonicalUnionCoupling
    }

    mutating func sample(_ context: PEXOpenRCXSourceModel.Context, width: Int64, distance: Int64?,
                         length: Int64, ids: [String], isCancelled: () -> Bool)
        throws(NativeRoutedPEXError) -> (fringe: Double, coupling: Double) {
        guard length > 0 else { throw .unrepresentableArithmetic }
        guard budget.remainingWork > 0 else { throw .limitExceeded(.workVisits) }
        let value: NativeRoutedRuleEvaluation
        do {
            value = try rules.evaluate(context: context, widthDatabaseUnits: width,
                distance: distance.map { .finite(databaseUnits: $0) } ?? .open,
                maximumWorkVisits: budget.remainingWork, isCancelled: isCancelled)
        } catch {
            if error == .cancelled { throw .cancelled }
            if error == .limitExceeded { throw .limitExceeded(.workVisits) }
            throw .rule(context: context, cause: error, sourceIDs: ids)
        }
        try budget.visit(value.workVisitsConsumed, isCancelled)
        let fringe = value.fringeFaradsPerDatabaseUnit * Double(length)
        let coupling = value.couplingFaradsPerDatabaseUnit * Double(length)
        guard fringe.isFinite, coupling.isFinite,
              value.fringeFaradsPerDatabaseUnit == 0 || fringe > 0,
              value.couplingFaradsPerDatabaseUnit == 0 || coupling > 0 else { throw .unrepresentableArithmetic }
        try budget.charge(.queryReceipts)
        queryReceipts.append(.init(sourceIDs: ids, context: context, requestedWidthDatabaseUnits: width,
            requestedDistanceDatabaseUnits: distance, evaluatedDistanceDatabaseUnits: value.evaluatedDistanceDatabaseUnits,
            selectedWidthMicrons: value.selectedWidthMicrons, tableSourceRange: value.tableSourceRange,
            sampleSourceRanges: value.sampleSourceRanges, effectiveLengthDatabaseUnits: length,
            couplingFarads: coupling, fringeFarads: fringe))
        return (fringe, coupling)
    }

    mutating func ground(_ owner: Int, _ span: Geometry.Interval, _ value: Double,
                         _ isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        try budget.visit(1, isCancelled)
        guard value.isFinite, value >= 0 else { throw .unrepresentableArithmetic }
        if purpose == .canonicalUnionCoupling { return }
        if value == 0 || geometry.roles[geometry.wires[owner].netName] == .reference { return }
        try budget.charge(.coordinateValues, 2)
        caps.append(.init(a: owner, b: nil, span: span, farads: value, reference: nil, queryReceiptIndex: queryReceipts.count - 1))
    }

    mutating func coupling(_ a: Int, _ b: Int, _ span: Geometry.Interval, _ value: Double,
                           _ isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        try budget.visit(1, isCancelled)
        guard value.isFinite, value >= 0 else { throw .unrepresentableArithmetic }
        if value == 0 { return }
        let ar = geometry.roles[geometry.wires[a].netName], br = geometry.roles[geometry.wires[b].netName]
        if ar == .reference || br == .reference {
            if ar == .reference && br == .reference { return }
            let signal = ar == .reference ? b : a
            if purpose == .canonicalUnionCoupling {
                try budget.charge(.coordinateValues, 2)
                caps.append(.init(a: signal, b: nil, span: span, farads: value,
                                  reference: ar == .reference ? a : b, queryReceiptIndex: queryReceipts.count - 1))
            } else { try ground(signal, span, value, isCancelled) }
            return
        }
        if geometry.wires[a].netName == geometry.wires[b].netName { return }
        try budget.charge(.coordinateValues, 4)
        caps.append(.init(a: a, b: b, span: span, farads: value, reference: nil, queryReceiptIndex: queryReceipts.count - 1))
    }

    mutating func apply(_ event: Events.Event, context: PEXOpenRCXSourceModel.Context,
                        span: Geometry.Interval, effectiveLength: Int64? = nil,
                        isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        let a = geometry.wires[event.source]
        let b = event.target.map { geometry.wires[$0] }
        let ids = [a.sourceID] + (b.map { [$0.sourceID] } ?? [])
        let length = effectiveLength ?? span.length
        if length <= 0 { return }
        let value = try sample(context, width: Events.width(a), distance: event.gap, length: length, ids: ids, isCancelled: isCancelled)
        if let target = event.target {
            let same = a.netName == geometry.wires[target].netName
            let fringe = same ? value.fringe * 0.5 : value.fringe
            try ground(event.source, span, fringe, isCancelled)
            try ground(target, span, fringe, isCancelled)
            if !same { try coupling(event.source, target, span, value.coupling, isCancelled) }
        } else {
            try ground(event.source, span, value.fringe, isCancelled)
        }
    }
}
