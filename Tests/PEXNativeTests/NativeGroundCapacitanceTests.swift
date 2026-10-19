import CircuiteFoundation
import Foundation
import PEXCore
import Synchronization
import Testing
@testable import PEXNative

@Suite("Source-bound union ground capacitance", .timeLimit(.minutes(1)))
struct NativeGroundCapacitanceTests {
    typealias Rect = NativeConductorUnion.Rect
    private let limits = NativeGroundCapacitanceLimits(maximumInputRecords: 100_000,
        maximumStringBytes: 100_000, maximumOutputRecords: 100_000, maximumWorkVisits: 100_000)
    private let unionLimits = NativeConductorUnionLimits(maximumInputRecords: 100_000,
        maximumStringBytes: 100_000, maximumUnionBands: 100_000,
        maximumBoundarySegments: 100_000, maximumContributorIndices: 100_000,
        maximumCoordinateValues: 100_000, maximumWorkVisits: 1_000_000)

    @Test func rectangleIncludesEachEndAndNoInternalMeshFace() throws {
        let model = try calibration()
        let union = try geometry([.init(minX: 0, minY: 0, maxX: 1000, maxY: 2000)], model: model)
        let result = try calculate(union, model)
        // Independent rectangle: area 2 um2 and complete perimeter 6 um.
        #expect(close(result.totalFarads, (2 * 2 + 3 * 6) * 1e-12))
        #expect(close(result.bandAreaContributions.reduce(0) { $0 + $1.farads }, 4e-12))
        #expect(close(result.boundaryContributions.reduce(0) { $0 + $1.farads }, 18e-12))
        #expect(result.union.boundaries.count == 4)
        #expect(result.model == model)
        #expect(result.model.algorithm.rawValue == "native-lef-area-boundary-v1")
    }

    @Test func actualShortTurnAndLandingUnionCountPhysicalMetalOnce() throws {
        let model = try calibration(area: 36.9866e-6, edge: 40.697e-6)
        let union = try geometry([
            .init(minX: 17165, minY: 5900, maxX: 17795, maxY: 6070),
            .init(minX: 17165, minY: 5865, maxX: 17335, maxY: 6070),
            .init(minX: 17165, minY: 5865, maxX: 17335, maxY: 6035)
        ], model: model)
        let result = try calculate(union, model)
        // Exact actual-source geometry: 113050 DBU2 union and 1670 DBU perimeter.
        #expect(close(result.totalFarads, 7.214532513e-17))
        #expect(close(result.bandAreaContributions.reduce(0) { $0 + $1.farads }, 4.18133513e-18))
        #expect(close(result.boundaryContributions.reduce(0) { $0 + $1.farads }, 6.796399e-17))
        var contributors = Set<Int>()
        for item in result.bandAreaContributions {
            #expect(item.contributorIndices == union.bands[item.bandIndex].contributorIndices)
            contributors.formUnion(item.contributorIndices)
        }
        for item in result.boundaryContributions {
            #expect(item.contributorIndices == union.boundaries[item.boundaryIndex].contributorIndices)
        }
        #expect(contributors == Set([0, 1, 2]))
        #expect(result.union.sources.count == 3)
        #expect(result.union.sources.allSatisfy { !$0.sourceFacts.isEmpty })
    }

    @Test func holeAndDisjointIslandsRetainTheirExternalBoundaries() throws {
        let model = try calibration()
        let ring = try geometry([
            .init(minX: 0, minY: 0, maxX: 3000, maxY: 1000),
            .init(minX: 0, minY: 2000, maxX: 3000, maxY: 3000),
            .init(minX: 0, minY: 1000, maxX: 1000, maxY: 2000),
            .init(minX: 2000, minY: 1000, maxX: 3000, maxY: 2000)
        ], model: model)
        // Outer 3x3, inner 1x1: area 8, outer+inner perimeter 16.
        #expect(close(try calculate(ring, model).totalFarads, 64e-12))
        let islands = try geometry([
            .init(minX: 0, minY: 0, maxX: 1000, maxY: 1000),
            .init(minX: 2000, minY: 0, maxX: 3000, maxY: 1000)
        ], model: model)
        #expect(close(try calculate(islands, model).totalFarads, 28e-12))
    }

    @Test func splitDuplicateReorderAndAxisSwapDoNotChooseAnotherCapacitance() throws {
        let model = try calibration()
        let whole = try geometry([.init(minX: 0, minY: 0, maxX: 1000, maxY: 2000)], model: model)
        let split = [Rect(minX: 0, minY: 0, maxX: 1000, maxY: 900),
                     Rect(minX: 0, minY: 900, maxX: 1000, maxY: 2000)]
        let variants = [split, Array(split.reversed()), split + [split[0]],
                        [.init(minX: 0, minY: 0, maxX: 2000, maxY: 1000)]]
        let expected = try calculate(whole, model).totalFarads
        for variant in variants {
            let value = try calculate(try geometry(variant, model: model), model)
            #expect(close(value.totalFarads, expected))
        }
    }

    @Test func rawCalibrationRoundTripPreservesCornerSourceAndOptionalThickness() throws {
        for corner in [PEXOpenRCXSourceModel.RCCorner.nominal, .minimum, .maximum] {
            let model = try calibration(corner: corner, thickness: nil)
            let decoded = try JSONDecoder().decode(PEXRoutedGroundCapacitanceModel.self,
                                                   from: JSONEncoder().encode(model))
            #expect(decoded == model)
            let union = try geometry([.init(minX: 0, minY: 0, maxX: 1000, maxY: 2000)], model: decoded)
            #expect(close(try calculate(union, decoded).totalFarads, 22e-12))
            #expect(decoded.layers.allSatisfy { $0.thicknessMicrons == nil })
        }
    }

    @Test func selectionCornerUnitsCoverageAndSourceRangesFailExplicitly() throws {
        let model = try calibration()
        let union = try geometry([.init(minX: 0, minY: 0, maxX: 1000, maxY: 2000)], model: model)
        let calculator = LEFAreaBoundaryGroundCapacitanceCalculator()
        let foreign = try calibration(corner: .minimum)
        #expect(throws: NativeGroundCapacitanceError.invalidInput(.selection)) {
            try calculator.calculate(union: union, model: model, selection: foreign.selection,
                cornerID: model.cornerID, limits: limits)
        }
        #expect(throws: NativeGroundCapacitanceError.invalidInput(.corner)) {
            try calculator.calculate(union: union, model: model, selection: model.selection,
                cornerID: "foreign", limits: limits)
        }
        #expect(throws: NativeGroundCapacitanceError.invalidInput(.units)) {
            try calculate(union, try calibration(unit: 1000))
        }
        #expect(throws: NativeGroundCapacitanceError.invalidInput(.layerCoverage)) {
            try calculate(union, replace(model, layers: Array(model.layers.dropLast())))
        }
        #expect(throws: NativeGroundCapacitanceError.invalidInput(.sourceRange)) {
            try calculate(union, try calibration(ranges: []))
        }
        #expect(throws: NativeGroundCapacitanceError.invalidInput(.sourceRange)) {
            try calculate(union, try calibration(ranges: [.init(lowerBound: 0, upperBound: 1001)]))
        }
    }

    @Test func nonfiniteNonpositiveAndUnrepresentablePositiveTermsNeverBecomeZero() throws {
        let model = try calibration()
        let union = try geometry([.init(minX: 0, minY: 0, maxX: 1000, maxY: 2000)], model: model)
        for value in [0.0, -1, .infinity, .nan] {
            #expect(throws: NativeGroundCapacitanceError.invalidInput(.coefficient)) {
                try calculate(union, try calibration(area: value))
            }
            #expect(throws: NativeGroundCapacitanceError.invalidInput(.coefficient)) {
                try calculate(union, try calibration(edge: value))
            }
        }
        for value in [Double.greatestFiniteMagnitude, .leastNonzeroMagnitude] {
            #expect(throws: NativeGroundCapacitanceError.unrepresentableArithmetic) {
                try calculate(union, try calibration(area: value))
            }
        }
    }

    @Test func tinyPhysicalIslandsRemainPositiveAndAccumulateBeyondOneRoundedAddition() throws {
        let model = try calibration(area: 2, edge: 1e-300)
        let large = Rect(minX: 0, minY: 0, maxX: 1_000_000_000, maxY: 1_000_000_000)
        func island(_ index: Int32) -> Rect {
            let x = 1_000_000_000 + 2 * (index + 1)
            return .init(minX: x, minY: 0, maxX: x + 1, maxY: 1)
        }
        let one = try calculate(try geometry([large, island(0)], model: model), model)
        #expect(one.totalFarads.isFinite && one.totalFarads == 2)
        #expect(one.bandAreaContributions.contains { $0.farads > 0 && $0.farads < 1e-17 })
        let islands = (0..<128).map { island(Int32($0)) }
        let many = try calculate(try geometry([large] + islands, model: model), model)
        let naive = many.bandAreaContributions.reduce(0.0) { $0 + $1.farads }
            + many.boundaryContributions.reduce(0.0) { $0 + $1.farads }
        #expect(naive == 2)
        #expect(many.totalFarads > naive)
        #expect(many.totalFarads == 2.0 + 128.0 * 2e-18)
        #expect(many.bandAreaContributions.allSatisfy { $0.farads.isFinite && $0.farads > 0 })
        #expect(many.boundaryContributions.allSatisfy { $0.farads.isFinite && $0.farads > 0 })
    }

    @Test func exactRunLimitsAndCancellationApplyToWholeCalculation() throws {
        let model = try calibration()
        let union = try geometry([.init(minX: 0, minY: 0, maxX: 1000, maxY: 2000)], model: model)
        let value = try calculate(union, model)
        func bounded(_ resource: NativeGroundCapacitanceError.Resource?, decrement: Int = 0) -> NativeGroundCapacitanceLimits {
            .init(maximumInputRecords: value.inputRecordsConsumed - (resource == .inputRecords ? decrement : 0),
                  maximumStringBytes: value.stringBytesConsumed - (resource == .stringBytes ? decrement : 0),
                  maximumOutputRecords: value.outputRecordsConsumed - (resource == .outputRecords ? decrement : 0),
                  maximumWorkVisits: value.workVisitsConsumed - (resource == .workVisits ? decrement : 0))
        }
        let calculator = LEFAreaBoundaryGroundCapacitanceCalculator()
        #expect(close(try calculator.calculate(union: union, model: model, selection: model.selection,
            cornerID: model.cornerID, limits: bounded(nil)).totalFarads, value.totalFarads))
        for resource in [NativeGroundCapacitanceError.Resource.inputRecords, .stringBytes, .outputRecords, .workVisits] {
            #expect(throws: NativeGroundCapacitanceError.limitExceeded(resource)) {
                try calculator.calculate(union: union, model: model, selection: model.selection,
                    cornerID: model.cornerID, limits: bounded(resource, decrement: 1))
            }
        }
        let polls = Mutex(0)
        #expect(throws: NativeGroundCapacitanceError.cancelled) {
            try calculator.calculate(union: union, model: model, selection: model.selection,
                cornerID: model.cornerID, limits: limits, isCancelled: {
                    polls.withLock { count in count += 1; return count == value.workVisitsConsumed }
                })
        }
    }

    @Test func sharedLedgerRemainsCumulativeAcrossSuccessAndLimitFailure() throws {
        let model = try calibration()
        let union = try geometry([.init(minX: 0, minY: 0, maxX: 1000, maxY: 2000)], model: model)
        let standalone = try calculate(union, model)
        var accounting: any NativeConductorResourceAccounting = Ledger(available: [
            .inputRecords: 2 * standalone.inputRecordsConsumed,
            .stringBytes: 2 * standalone.stringBytesConsumed,
            .graphElements: 2 * standalone.outputRecordsConsumed,
            .workVisits: 2 * standalone.workVisitsConsumed - 1])
        let calculator = LEFAreaBoundaryGroundCapacitanceCalculator()
        let shared = try calculator.calculate(union: union, model: model, selection: model.selection,
            cornerID: model.cornerID, accounting: &accounting, isCancelled: { false })
        #expect(shared.totalFarads == standalone.totalFarads)
        #expect(shared.bandAreaContributions == standalone.bandAreaContributions)
        #expect(shared.boundaryContributions == standalone.boundaryContributions)
        #expect(accounting.remaining(.workVisits) == standalone.workVisitsConsumed - 1)
        #expect(accounting.remaining(.inputRecords) == standalone.inputRecordsConsumed)
        #expect(throws: NativeGroundCapacitanceError.conductor(.limitExceeded(.workVisits))) {
            try calculator.calculate(union: union, model: model, selection: model.selection,
                cornerID: model.cornerID, accounting: &accounting, isCancelled: { false })
        }
        #expect(accounting.remaining(.workVisits) == 0)
        #expect(accounting.remaining(.inputRecords) == 0)
        #expect(accounting.remaining(.stringBytes) == 0)
        #expect(accounting.remaining(.graphElements) == 0)
    }

    @Test func sharedLedgerRetainsSpentResourcesOnSourceRefusalAndCancellation() throws {
        let model = try calibration()
        let union = try geometry([.init(minX: 0, minY: 0, maxX: 1000, maxY: 2000)], model: model)
        var accounting: any NativeConductorResourceAccounting = Ledger(available: [
            .inputRecords: unionLimits.maximumInputRecords,
            .stringBytes: unionLimits.maximumStringBytes,
            .graphElements: limits.maximumOutputRecords,
            .workVisits: unionLimits.maximumWorkVisits])
        let calculator = LEFAreaBoundaryGroundCapacitanceCalculator()
        let foreign = try calibration(corner: .minimum)
        #expect(throws: NativeGroundCapacitanceError.invalidInput(.selection)) {
            try calculator.calculate(union: union, model: model, selection: foreign.selection,
                cornerID: model.cornerID, accounting: &accounting, isCancelled: { false })
        }
        #expect(accounting.remaining(.workVisits) == unionLimits.maximumWorkVisits - 1)
        #expect(accounting.remaining(.stringBytes) < unionLimits.maximumStringBytes)
        let workBefore = accounting.remaining(.workVisits)
        let inputsBefore = accounting.remaining(.inputRecords)
        let polls = Mutex(0)
        #expect(throws: NativeGroundCapacitanceError.cancelled) {
            try calculator.calculate(union: union, model: model, selection: model.selection,
                cornerID: model.cornerID, accounting: &accounting, isCancelled: {
                    polls.withLock { count in count += 1; return count == 2 }
                })
        }
        #expect(accounting.remaining(.workVisits) == workBefore - 1)
        #expect(accounting.remaining(.inputRecords) == inputsBefore - 1)
    }

    private func calculate(_ union: NativeConductorUnion, _ model: PEXRoutedGroundCapacitanceModel)
        throws -> NativeGroundCapacitanceResult {
        try LEFAreaBoundaryGroundCapacitanceCalculator().calculate(union: union, model: model,
            selection: model.selection, cornerID: model.cornerID, limits: limits)
    }
    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= abs(b) * 1e-12 }

    private struct Ledger: NativeConductorResourceAccounting {
        var available: [NativeConductorResource: Int]
        func remaining(_ resource: NativeConductorResource) -> Int { available[resource, default: 0] }
        mutating func charge(_ resource: NativeConductorResource, count: Int) throws(NativeConductorError) {
            guard count >= 0 else { throw .arithmeticOverflow }
            guard count <= remaining(resource) else { throw .limitExceeded(resource) }
            available[resource, default: 0] -= count
        }
        mutating func visit(_ count: Int, isCancelled: @Sendable () -> Bool) throws(NativeConductorError) {
            if isCancelled() { throw .cancelled }
            try charge(.workVisits, count: count)
        }
    }

    private func calibration(area: Double = 2, edge: Double = 3, unit: Double = 1,
                             corner: PEXOpenRCXSourceModel.RCCorner = .nominal,
                             thickness: Double? = 0.1,
                             ranges: [PEXOpenRCXSourceModel.SourceRange] = [.init(lowerBound: 0, upperBound: 10)])
        throws -> PEXRoutedGroundCapacitanceModel {
        let marker = corner == .nominal ? "ab" : corner == .minimum ? "bc" : "cd"
        let artifact = try ArtifactID(digest: .init(algorithm: .sha256,
            hexadecimalValue: String(repeating: marker, count: 32)), byteCount: 1000)
        let names = ["li1", "met1", "met2", "met3", "met4", "met5"]
        let selection = PEXOpenRCXSourceModel.Selection(processName: "synthetic-ground-source", corner: corner,
            rulesArtifactID: artifact, technologyLEFArtifactID: artifact, routingLayerNames: names)
        return .init(selection: selection, cornerID: .init(corner.rawValue), capacitanceUnitPicofarads: unit,
            unitSourceRanges: ranges, layers: names.map { .init(name: $0,
                areaPicofaradsPerSquareMicron: area, edgePicofaradsPerMicron: edge,
                thicknessMicrons: thickness, sourceRanges: ranges) })
    }
    private func replace(_ model: PEXRoutedGroundCapacitanceModel,
                         layers: [PEXRoutedGroundCapacitanceModel.Layer]) -> PEXRoutedGroundCapacitanceModel {
        .init(selection: model.selection, cornerID: model.cornerID,
              capacitanceUnitPicofarads: model.capacitanceUnitPicofarads,
              unitSourceRanges: model.unitSourceRanges, layers: layers)
    }
    private func geometry(_ rects: [Rect], model: PEXRoutedGroundCapacitanceModel) throws -> NativeConductorUnion {
        let sources = rects.enumerated().map { index, rect in
            NativeConductorUnion.Source(sourceID: "metal.\(index)", netName: NetName("N"), layerName: "li1", rect: rect,
                sourceFacts: [.init(artifactID: model.selection.technologyLEFArtifactID,
                                    byteRange: .init(lowerBound: index, upperBound: index + 1))])
        }
        return try RectilinearConductorUnionBuilder().build(sources: sources, databaseUnitsPerMicron: 1000,
            limits: unionLimits, isCancelled: { false })
    }
}
