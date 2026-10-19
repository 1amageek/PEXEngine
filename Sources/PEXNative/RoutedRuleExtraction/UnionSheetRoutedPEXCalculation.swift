import PEXCore

struct UnionSheetRoutedPEXCalculation {
    typealias Input = NativeRoutedPEXInput
    typealias Rect = NativeConductorUnion.Rect
    let input: Input
    let model: PEXOpenRCXSourceModel
    let groundModel: PEXRoutedGroundCapacitanceModel
    let span: Int32
    var budget: NativeRoutedPEXWorkBudget
    var sourceOrigins: [String: String] = [:]
    var attachments: [NativeUnionSheetPEXEvidence.Attachment] = []

    init(input: Input, model: PEXOpenRCXSourceModel, groundModel: PEXRoutedGroundCapacitanceModel,
         span: Int32, limits: NativeRoutedPEXLimits) throws(NativeRoutedPEXError) {
        guard span > 0 else { throw .invalidInput(reason: .units, sourceIDs: []) }
        self.input = input; self.model = model; self.groundModel = groundModel; self.span = span
        budget = try .init(limits)
    }

    mutating func run(cornerID: PEXCornerID, isCancelled: @Sendable () -> Bool)
        throws(NativeRoutedPEXError) -> NativeRoutedPEXResult {
        let geometry = try NativeRoutedPEXGeometry(input: input, model: model, budget: &budget,
                                                   isCancelled: isCancelled, areaContacts: true)
        let sources = try unionSources(isCancelled)
        let units = input.databaseUnitsPerMicron, cellSpan = span
        let calibration = groundModel, selection = input.selection
        let union = try lower { accounting in
            try RectilinearConductorUnionBuilder().build(sources: sources,
                databaseUnitsPerMicron: units, accounting: &accounting, isCancelled: isCancelled)
        }
        let sheetInput = try resistanceInput(union: union, geometry: geometry, isCancelled: isCancelled)
        let sheet = try lower { accounting in
            try RectilinearSheetResistanceCalculator().calculate(input: sheetInput,
                maximumCellSpanDatabaseUnits: cellSpan, accounting: &accounting, isCancelled: isCancelled)
        }
        let ground = try lower { accounting in
            try LEFAreaBoundaryGroundCapacitanceCalculator().calculate(union: union, model: calibration,
                selection: selection, cornerID: cornerID, accounting: &accounting, isCancelled: isCancelled)
        }
        var graph = try UnionSheetRoutedPEXGraph(sheet: sheet, input: input, budget: &budget, isCancelled: isCancelled)
        try attachGround(ground, sheet: sheet, graph: &graph, geometry: geometry, isCancelled: isCancelled)
        let wires = try queryWires(union: union, isCancelled: isCancelled)
        let queryGeometry = NativeRoutedPEXGeometry(admitted: geometry, queryWires: wires, conductorUnion: union)
        var queries = try NativeRoutedPEXCalculation(geometry: queryGeometry, model: model,
                                                     budget: &budget, isCancelled: isCancelled)
        do { try queries.capacitance(isCancelled) }
        catch { budget = queries.budget; throw error }
        budget = queries.budget
        try attachCoupling(queries, union: union, sheet: sheet, graph: &graph, isCancelled: isCancelled)
        let receipts = try originalQueryReceipts(queries.queryReceipts, union: union, isCancelled: isCancelled)
        let observations = try NativeUnionSheetEvidenceProjection.project(union: union, sheet: sheet, graph: graph,
            sourceOrigins: sourceOrigins, attachments: attachments, maximumCellSpanDatabaseUnits: span,
            budget: &budget, isCancelled: isCancelled)
        let metadata = ["native.routed.profile": model.profile.rawValue,
            "native.routed.discretization": "native-union-sheet-area-boundary-v1",
            "native.routed.resistanceModel": "finite-volume-sheet-cut-area-dirichlet-v1",
            "native.routed.groundModel": "lef-area-boundary-v1",
            "native.routed.couplingModel": "canonical-union-band-openrcx-empirical-cc-v1",
            "native.routed.rcCorner": input.selection.corner.rawValue,
            "native.routed.rulesSHA256": input.selection.rulesArtifactID.digest.hexadecimalValue,
            "native.routed.pinCapacitance": "excluded",
            "native.routed.referenceDiagonalEmission": "explicit-source-coupling-ground-conversion",
            "native.routed.legacyCombinedFringe": "queried-only-not-emitted",
            "native.routed.qualification": "independent-qualification-required"]
        let ir = try graph.finish(cornerID: cornerID, metadata: metadata, budget: &budget, isCancelled: isCancelled)
        return .init(ir: ir, selection: input.selection, sourceFacts: geometry.sourceFacts,
            queryReceipts: receipts, viaLandingReceipts: [], workVisitsConsumed: budget.workVisitsConsumed,
            unionSheetEvidence: observations)
    }

    /// Synchronous value-only loan; lower failures return the same spent ledger.
    mutating func lower<T>(_ operation: (inout any NativeConductorResourceAccounting) throws -> T)
        throws(NativeRoutedPEXError) -> T {
        var accounting: any NativeConductorResourceAccounting = NativeRoutedConductorAccounting(budget: budget)
        let outcome: Result<T, any Error> = Result { try operation(&accounting) }
        guard let returned = accounting as? NativeRoutedConductorAccounting else {
            throw .unsupportedNumericalLaw(reason: "The numerical component replaced the borrowed ledger owner")
        }
        budget = returned.budget
        do { return try outcome.get() }
        catch let error as NativeConductorError { throw mapped(error) }
        catch let error as NativeSheetResistanceError {
            if case .conductor(let cause) = error { throw mapped(cause) }
            throw .sheetResistance(error)
        } catch let error as NativeGroundCapacitanceError {
            if case .conductor(let cause) = error { throw mapped(cause) }
            if error == .cancelled { throw .cancelled }
            throw .groundCapacitance(error)
        } catch { throw .unsupportedNumericalLaw(reason: "Unexpected numerical component failure: \(error)") }
    }
    private func mapped(_ error: NativeConductorError) -> NativeRoutedPEXError {
        switch error {
        case .cancelled: .cancelled
        case .arithmeticOverflow: .unrepresentableArithmetic
        case .limitExceeded(let resource): .limitExceeded(NativeRoutedConductorAccounting.resource(resource))
        default: .conductor(error)
        }
    }
    func rectangle(_ source: Input.Rect) throws(NativeRoutedPEXError) -> Rect {
        guard let x0 = Int32(exactly: source.minX), let y0 = Int32(exactly: source.minY),
              let x1 = Int32(exactly: source.maxX), let y1 = Int32(exactly: source.maxY) else {
            throw .unrepresentableArithmetic
        }
        return .init(minX: x0, minY: y0, maxX: x1, maxY: y1)
    }
    mutating func generated(_ prefix: String, _ index: Int) throws(NativeRoutedPEXError) -> String {
        guard index >= 0 else { throw .unrepresentableArithmetic }
        var digits = 1, remainder = index
        while remainder >= 10 { digits += 1; remainder /= 10 }
        let count = prefix.utf8.count.addingReportingOverflow(digits)
        guard !count.overflow else { throw .unrepresentableArithmetic }
        try budget.charge(.stringBytes, count.partialValue)
        return "\(prefix)\(index)"
    }
}
