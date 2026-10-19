import CircuiteFoundation
import PEXCore
import PEXNative
import Testing

@Suite("Pinned routed rule numerical law", .timeLimit(.minutes(1)))
struct RoutedRuleExtractionTests {
    private let over = PEXOpenRCXSourceModel.Context(metal: 1, kind: .over, underMetal: 0)

    private func model(context: PEXOpenRCXSourceModel.Context? = nil,
                       rows: [(Double, Double, Double, Double)] = [(0, 10, 1, 2), (0.01, 20, 2, 4), (0.02, 30, 3, 6)]) throws -> PEXOpenRCXSourceModel {
        let selected = context ?? over
        let artifact = try ArtifactID(digest: .init(algorithm: .sha256, hexadecimalValue: String(repeating: "ab", count: 32)), byteCount: 1_000_000)
        var families: [PEXOpenRCXSourceModel.Family] = []
        var tables: [PEXOpenRCXSourceModel.Table] = []
        for metal in 1...6 {
            var kinds: [PEXOpenRCXSourceModel.Kind] = [.resOver, .over, .under, .diagUnder]
            if (2...5).contains(metal) { kinds.append(.overUnder) }
            for kind in kinds {
                let start = 100 + families.count * 20_000
                let width = [0.17, 0.14, 0.14, 0.3, 0.3, 1.6][metal - 1]
                families.append(.init(metal: metal, kind: kind,
                    widthsMicrons: metal == 6 && (kind == .under || kind == .diagUnder) ? [] : [width],
                    sourceRange: .init(lowerBound: start, upperBound: start + 20_000)))
                var contexts: [PEXOpenRCXSourceModel.Context] = []
                switch kind {
                case .resOver, .over:
                    contexts = (0..<metal).map { .init(metal: metal, kind: kind, underMetal: $0) }
                case .under, .diagUnder:
                    if metal < 6 { contexts = ((metal + 1)...6).map { .init(metal: metal, kind: kind, overMetal: $0) } }
                case .overUnder:
                    for lower in 1..<metal { for upper in (metal + 1)...6 {
                        contexts.append(.init(metal: metal, kind: kind, underMetal: lower, overMetal: upper))
                    } }
                }
                for (index, current) in contexts.enumerated() {
                    let tableStart = start + index * 100
                    let samples: [PEXOpenRCXSourceModel.CapacitanceSample] = current == selected ? rows.enumerated().map { offset, row in
                        .init(distanceMicrons: row.0, couplingFemtofaradsPerNanometer: row.1,
                            fringeFemtofaradsPerNanometer: row.2, resistanceOhmsPerNanometer: row.3,
                            sourceRange: .init(lowerBound: tableStart + 10 + offset, upperBound: tableStart + 11 + offset))
                    } : []
                    tables.append(.init(context: current, widthMicrons: width,
                        sourceRange: .init(lowerBound: tableStart, upperBound: tableStart + 100), capacitanceSamples: samples))
                }
            }
        }
        return try .init(selection: .init(processName: "synthetic-source-law", corner: .nominal,
            rulesArtifactID: artifact, technologyLEFArtifactID: artifact,
            routingLayerNames: ["li1", "met1", "met2", "met3", "met4", "met5"]),
            sourceHeaderRange: .init(lowerBound: 0, upperBound: 100), families: families, tables: tables)
    }

    private func evaluate(_ source: PEXOpenRCXSourceModel, _ distance: NativeRoutedRuleDistance,
                          width: Int64 = 230, scale: Int64 = 1000,
                          context: PEXOpenRCXSourceModel.Context? = nil) throws -> NativeRoutedRuleEvaluation {
        let evaluator: any NativeRoutedRuleEvaluating = try PinnedOpenRCXRuleEvaluator(model: source, databaseUnitsPerMicron: scale)
        return try evaluator.evaluate(context: context ?? over, widthDatabaseUnits: width,
            distance: distance, maximumWorkVisits: 10_000, isCancelled: { false })
    }

    private func close(_ actual: Double, _ expected: Double) -> Bool {
        abs(actual - expected) <= max(1e-30, abs(expected) * 1e-12)
    }

    @Test func positivePhysicalWidthsSelectPinnedBucketAndOpenIsNotFiniteZero() throws {
        let source = try model()
        for width: Int64 in [1, 170, 230, 1000] {
            let zero = try evaluate(source, .finite(databaseUnits: 0), width: width)
            let open = try evaluate(source, .open, width: width)
            #expect(zero.selectedWidthMicrons == 0.17)
            #expect(close(zero.couplingFaradsPerDatabaseUnit, 10e-15))
            #expect(close(open.fringeFaradsPerDatabaseUnit, 3e-15))
            #expect(open.evaluatedDistanceDatabaseUnits == nil)
            #expect(open.sampleSourceRanges != zero.sampleSourceRanges)
        }
    }

    @Test func interiorUsesFourDBUGridAndOrdinaryLastRowPlateau() throws {
        let source = try model()
        let value = try evaluate(source, .finite(databaseUnits: 15))
        #expect(value.evaluatedDistanceDatabaseUnits == 14)
        #expect(close(value.couplingFaradsPerDatabaseUnit, 24e-15))
        #expect(close(value.resistanceOhmsPerDatabaseUnit, 4.8))
        #expect(value.sampleSourceRanges.count == 2)
        for d: Int64 in [16, 20, 1000] {
            #expect(close(try evaluate(source, .finite(databaseUnits: d)).couplingFaradsPerDatabaseUnit, 30e-15))
        }
    }

    @Test func ordinaryShortDistancePreservesUnsignedPlateauThreshold() throws {
        let source = try model(rows: [(0, 10, 1, 2), (0.001, 20, 2, 4), (0.002, 30, 3, 6)])
        let value = try evaluate(source, .finite(databaseUnits: 1))
        #expect(close(value.couplingFaradsPerDatabaseUnit, 20e-15))
        #expect(value.evaluatedDistanceDatabaseUnits == 1)
    }

    @Test func defScaleChangesGridAndPerDBUCoefficient() throws {
        let value = try evaluate(model(), .finite(databaseUnits: 30), scale: 2000)
        #expect(value.evaluatedDistanceDatabaseUnits == 28)
        #expect(close(value.couplingFaradsPerDatabaseUnit, 12e-15))
        #expect(close(value.fringeFaradsPerDatabaseUnit, 1.2e-15))
    }

    @Test func farSentinelsRetainFiniteFringeAndInverseDistanceCoupling() throws {
        let source = try model(rows: [(0, 12, 2, 1), (0.01, 8, 4, 2), (99, 1, 6, 3), (100, 0, 7, 4)])
        let finite = try evaluate(source, .finite(databaseUnits: 10))
        let far = try evaluate(source, .finite(databaseUnits: 15))
        #expect(close(finite.couplingFaradsPerDatabaseUnit, 8e-15))
        #expect(close(far.couplingFaradsPerDatabaseUnit, 8e-15 * 10 / 15))
        #expect(close(far.fringeFaradsPerDatabaseUnit, 4e-15))
        #expect(close(try evaluate(source, .finite(databaseUnits: 21)).fringeFaradsPerDatabaseUnit, 7e-15))
        #expect(close(try evaluate(source, .open).fringeFaradsPerDatabaseUnit, 7e-15))
    }

    @Test func diagonalUsesFringeColumnAndActualSourceZeroIsValid() throws {
        let diagonal = PEXOpenRCXSourceModel.Context(metal: 1, kind: .diagUnder, overMetal: 2)
        let source = try model(context: diagonal, rows: [(0, 0, 3e-5, 0.034)])
        let result = try evaluate(source, .finite(databaseUnits: 0), context: diagonal)
        #expect(result.couplingFaradsPerDatabaseUnit == 0)
        #expect(close(result.physicalCouplingFaradsPerDatabaseUnit, 3e-20))
    }

    @Test func unavailableAndEmptyActiveQueriesNeverBecomeZero() throws {
        let source = try model()
        #expect(throws: NativeRoutedRuleError.emptyActiveTable) {
            try evaluate(source, .open, context: .init(metal: 2, kind: .over, underMetal: 0))
        }
        #expect(throws: NativeRoutedRuleError.unavailableContext) {
            try evaluate(source, .open, context: .init(metal: 1, kind: .over, underMetal: 9))
        }
        #expect(throws: NativeRoutedRuleError.resistanceOnlyContext) {
            try evaluate(source, .open, context: .init(metal: 1, kind: .resOver, underMetal: 0))
        }
    }

    @Test func cancellationLimitsAndUnrepresentableDimensionsRefuse() throws {
        let source = try model(), evaluator = try PinnedOpenRCXRuleEvaluator(model: source, databaseUnitsPerMicron: 1000)
        #expect(throws: NativeRoutedRuleError.cancelled) {
            try evaluator.evaluate(context: over, widthDatabaseUnits: 170,
                distance: .open, isCancelled: { true })
        }
        #expect(throws: NativeRoutedRuleError.limitExceeded) {
            try PinnedOpenRCXRuleEvaluator(model: source, databaseUnitsPerMicron: 1000, maximumSourceRecords: 1, isCancelled: { false })
        }
        #expect(throws: NativeRoutedRuleError.invalidQuery) { try evaluate(source, .open, width: 0) }
        #expect(throws: NativeRoutedRuleError.unrepresentableArithmetic) {
            try evaluate(model(rows: [(0.0011, 1, 1, 1), (0.0012, 2, 2, 2)]), .open)
        }
    }
}

@Suite("Pinned explicit LEF routed resistance", .timeLimit(.minutes(1)))
struct RoutedLEFResistanceTests {
    @Test func wireUsesActualLengthWidthAndCutArrayUsesPinnedAverageLaw() throws {
        let evaluator: any NativeRoutedLEFResistanceEvaluating = PinnedRoutedLEFResistanceEvaluator()
        #expect(try evaluator.wire(sheetResistanceOhmsPerSquare: 0.125, lengthDatabaseUnits: 10_000,
                                  widthDatabaseUnits: 200) == 6.25)
        #expect(try evaluator.via(cutResistanceOhms: [8, 8, 8, 8], maximumCuts: 10, isCancelled: { false }) == 2)
        #expect(try evaluator.via(cutResistanceOhms: [4, 12], maximumCuts: 10, isCancelled: { false }) == 4)
    }

    @Test func doubleEngineeringArithmeticCarriesExplicitFloatOracleRoundoffBound() throws {
        let actual = try PinnedRoutedLEFResistanceEvaluator().via(cutResistanceOhms: [9.3, 9.3])
        #expect(actual == 4.65)
        let oracleAverage = Float((9.3 + 9.3) / 2)
        let oracleResistance = oracleAverage / Float(2)
        // Propagate half an average-cast ULP through division by two, then add
        // half the final Float division ULP; this is input-specific uncertainty.
        let roundoffBound = Double(oracleAverage.ulp) / 4 + Double(oracleResistance.ulp) / 2
        let discrepancy = abs(actual - Double(oracleResistance))
        #expect(discrepancy > 0)
        #expect(discrepancy <= roundoffBound)
    }

    @Test func unavailableResistanceCancellationAndBoundsFailExplicitly() throws {
        let evaluator = PinnedRoutedLEFResistanceEvaluator()
        #expect(throws: NativeRoutedRuleError.invalidQuery) {
            try evaluator.wire(sheetResistanceOhmsPerSquare: 0, lengthDatabaseUnits: 100, widthDatabaseUnits: 10)
        }
        #expect(throws: NativeRoutedRuleError.invalidQuery) { try evaluator.via(cutResistanceOhms: []) }
        #expect(throws: NativeRoutedRuleError.invalidQuery) { try evaluator.via(cutResistanceOhms: [4, 0]) }
        #expect(throws: NativeRoutedRuleError.limitExceeded) { try evaluator.via(cutResistanceOhms: [4, 4], maximumCuts: 1) }
        #expect(throws: NativeRoutedRuleError.cancelled) { try evaluator.via(cutResistanceOhms: [4], isCancelled: { true }) }
        #expect(throws: NativeRoutedRuleError.unrepresentableArithmetic) { try evaluator.via(cutResistanceOhms: [.greatestFiniteMagnitude, .greatestFiniteMagnitude]) }
    }
}
