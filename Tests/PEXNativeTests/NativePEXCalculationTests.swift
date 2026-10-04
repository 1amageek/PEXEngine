import Foundation
import CircuiteFoundation
import LayoutCore
import LayoutTech
import LayoutVerify
import PEXCore
import Testing
@testable import PEXNative

@Suite("Native PEX numeric graph", .timeLimit(.minutes(1)))
struct NativePEXCalculationTests {
    private let fixture = NativePEXTestFixture()

    private func shape(_ layer: LayoutLayerID, _ x: Double = 0, _ y: Double = 0,
                       _ width: Double = 1, _ height: Double = 1) -> LayoutShape {
        var value = fixture.rect(x, y, width, height)
        value.layer = layer
        return value
    }

    private func technology(conductors: [PEXConductorElectricalModel]? = nil,
                            vias: [PEXViaElectricalModel]? = nil,
                            couplings: [PEXCouplingElectricalModel]? = nil,
                            stack: [TechnologyLayer]? = nil) throws -> TechnologyIR {
        let source = try fixture.technology(), old = source.electricalModels![0]
        let selectedVias = vias ?? old.vias
        let model = PEXElectricalModel(law: old.law, processName: old.processName, cornerID: old.cornerID,
            temperatureKelvin: old.temperatureKelvin, voltageVolts: old.voltageVolts, parameters: old.parameters,
            referenceNodeName: old.referenceNodeName, calibrationArtifacts: old.calibrationArtifacts,
            conductors: conductors ?? old.conductors, vias: selectedVias, couplings: couplings ?? old.couplings)
        return TechnologyIR(processName: source.processName, stack: stack ?? source.stack,
            logicalToPhysicalLayerMap: source.logicalToPhysicalLayerMap,
            vias: selectedVias.map { TechnologyVia(name: $0.viaName, topLayer: $0.topLayerName, bottomLayer: $0.bottomLayerName) },
            defaultExtractionRules: source.defaultExtractionRules, backendHints: source.backendHints, electricalModels: [model])
    }

    private func conductor(_ name: String = "M1", bottom: Double = 0, area: Double = 1e-4,
                           perimeter: Double = 1e-10,
                           width: PEXDimensionRangeMeters = .init(minimumMeters: 1e-12, maximumMeters: 10),
                           length: PEXDimensionRangeMeters = .init(minimumMeters: 1e-12, maximumMeters: 10)) -> PEXConductorElectricalModel {
        .init(layerName: name, bottomHeightMeters: bottom, thicknessMeters: 1e-6, resistivityOhmMeters: 2e-8,
            groundAreaFaradsPerSquareMeter: area, groundPerimeterFaradsPerMeter: perimeter, widthRange: width, lengthRange: length)
    }

    private func network(_ cell: LayoutCell, span: Int32 = 1_000, technology supplied: TechnologyIR? = nil,
                         limits: NativePEXCalculationLimits = .default) throws -> NativePEXNetwork {
        let calculator: any NativePEXCalculating = RectilinearPEXCalculator()
        return try calculator.calculate(snapshot: fixture.snapshot(cell), technology: supplied ?? fixture.technology(),
            corner: PEXCorner(id: "tt"), layerNames: fixture.bindings,
            maximumCellSpanDatabaseUnits: span, limits: limits, isCancelled: { Task.isCancelled })
    }

    private func capacitance(_ network: NativePEXNetwork, _ kind: NativePEXNetwork.Capacitor.Kind) -> Double {
        network.capacitors.filter { $0.kind == kind }.reduce(0) { $0 + $1.farads }
    }

    private func close(_ actual: Double, _ expected: Double) -> Bool {
        abs(actual - expected) <= abs(expected) * 1e-12
    }

    @Test func sheetResistanceUsesSharedFaceAndCellCenterDistance() throws {
        let result = try network(LayoutCell(name: "SHEET", shapes: [fixture.rect(0, 0, 3, 1)]))
        #expect(result.nodes.count == 3 && result.resistors.count == 2)
        #expect(result.resistors.allSatisfy { $0.kind == .sheet && close($0.ohms, 0.02) })
        // These are center-to-center operators, not the full end-electrode resistance.
        #expect(close(result.resistors.reduce(0) { $0 + $1.ohms }, 0.04))
    }

    @Test func nonuniformNeighborDistanceIsNotAssumedToBeOneGridStep() throws {
        let cell = LayoutCell(name: "UNEQUAL", shapes: [fixture.rect(0, 0, 1.5, 1)])
        let result = try network(cell)
        #expect(result.nodes.count == 2 && result.resistors.count == 1)
        #expect(close(result.resistors[0].ohms, 0.015))
    }

    @Test func groundUnionAreaAndExposedPerimeterSurviveOverlapAndRefinement() throws {
        let overlapping = LayoutCell(name: "UNION", shapes: [fixture.rect(0, 0, 2, 1), fixture.rect(1, 0, 2, 1)])
        let single = LayoutCell(name: "SINGLE", shapes: [fixture.rect(0, 0, 3, 1)])
        for result in [try network(overlapping), try network(overlapping, span: 250), try network(single)] {
            #expect(close(capacitance(result, .ground), 1.1e-15))
            #expect(capacitance(result, .coplanar) == 0)
            #expect(result.capacitors.allSatisfy { $0.nodeB == nil })
        }
    }

    @Test func concaveBoundaryCountsActualExposedEdges() throws {
        let polygon = LayoutShape(layer: fixture.m1, geometry: .polygon(.init(points: [
            .init(x: 0, y: 0), .init(x: 4, y: 0), .init(x: 4, y: 1),
            .init(x: 1, y: 1), .init(x: 1, y: 4), .init(x: 0, y: 4)])))
        let result = try network(LayoutCell(name: "L", shapes: [polygon]))
        #expect(close(capacitance(result, .ground), 7e-16 + 16e-16))
    }

    @Test func applicabilityUsesPhysicalRunsInsteadOfArtificialCellWidth() throws {
        let old = try fixture.technology().electricalModels![0]
        let layer = conductor(width: .init(minimumMeters: 0.9e-6, maximumMeters: 1.1e-6),
                              length: .init(minimumMeters: 1.9e-6, maximumMeters: 2.1e-6))
        let tech = try technology(conductors: [layer, old.conductors[1]])
        let result = try network(LayoutCell(name: "RANGE", shapes: [fixture.rect(0, 0, 2, 1)]), span: 250, technology: tech)
        #expect(result.nodes.count == 32)
        #expect(throws: NativePEXCalculationError.electricalModel(.outOfRange(field: "M1.occupiedWidth"))) {
            try network(LayoutCell(name: "NARROW", shapes: [fixture.rect(0, 0, 2, 0.5)]), technology: tech)
        }
    }

    @Test func cutResistancePreservesPerCutConductanceUnderSubdivision() throws {
        let cell = LayoutCell(name: "CUT", shapes: [shape(fixture.m1), shape(fixture.m2), shape(fixture.cut)])
        for span: Int32 in [1_000, 250] {
            let result = try network(cell, span: span)
            let cuts = result.nodes.indices.filter { result.nodes[$0].kind == .cut(viaName: "VIA1") }
            #expect(cuts.count == 1)
            for layer in ["M1", "M2"] {
                let conductance = result.resistors.filter { $0.kind == .cut && result.nodes[$0.nodeB].layerName == layer }
                    .reduce(0) { $0 + 1 / $1.ohms }
                #expect(close(conductance, 1))
            }
            #expect(capacitance(result, .interlayer) == 0)
        }
    }

    @Test func oneViaDefinitionWithTwoCutsProducesTwoIndependentCutNodes() throws {
        var layoutTech = LayoutTechDatabase.standard()
        let first = LayoutRect(origin: .zero, size: .init(width: 1, height: 1))
        let second = LayoutRect(origin: .init(x: 3, y: 0), size: first.size)
        layoutTech.vias[0].layerGeometries = [fixture.cut, fixture.m1, fixture.m2].map {
            .init(layer: $0, rects: [first, second])
        }
        let cell = LayoutCell(name: "ARRAY", vias: [LayoutVia(viaDefinitionID: "VIA1", position: .zero)])
        let source = try fixture.snapshot(cell, tech: layoutTech)
        let result = try RectilinearPEXCalculator().calculate(snapshot: source, technology: fixture.technology(),
            corner: PEXCorner(id: "tt"), layerNames: fixture.bindings, maximumCellSpanDatabaseUnits: 1_000)
        #expect(result.snapshot.components.count == 2)
        #expect(result.nodes.filter { $0.kind == .cut(viaName: "VIA1") }.count == 2)
        #expect(result.resistors.count == 4 && result.resistors.allSatisfy { $0.kind == .cut && close($0.ohms, 1) })
        #expect(result.resistors.allSatisfy { result.nodes[$0.nodeA].componentIndex == result.nodes[$0.nodeB].componentIndex })
    }

    @Test func namedViaSelectsItsDefinitionDespiteAnotherApplicableRawCutModel() throws {
        let old = try fixture.technology().electricalModels![0]
        let alternate = PEXViaElectricalModel(viaName: "ALTERNATE", cutLayerName: "C1", bottomLayerName: "M1",
            topLayerName: "M2", resistanceOhmsPerCut: 9, cutWidthRange: old.vias[0].cutWidthRange,
            cutHeightRange: old.vias[0].cutHeightRange)
        let tech = try technology(vias: old.vias + [alternate])
        let named = try network(LayoutCell(name: "NAMED", vias: [LayoutVia(viaDefinitionID: "VIA1", position: .zero)]), technology: tech)
        #expect(named.resistors.filter { $0.kind == .cut }.allSatisfy { close($0.ohms, 1) })
        #expect(throws: NativePEXCalculationError.ambiguousCutModel) {
            try network(LayoutCell(name: "RAW", shapes: [shape(fixture.m1), shape(fixture.m2), shape(fixture.cut)]), technology: tech)
        }
    }

    @Test func missingOrPartialCutElectrodeFailsExplicitly() throws {
        for shapes in [[shape(fixture.m1), shape(fixture.cut)],
                       [shape(fixture.m1), shape(fixture.m2, 0, 0, 0.5), shape(fixture.cut)]] {
            #expect(throws: NativePEXCalculationError.incompleteCutContact) {
                try network(LayoutCell(name: "PARTIAL", shapes: shapes))
            }
        }
    }

    @Test func nonrectangularCutAndOutOfRangeDimensionsFailExplicitly() throws {
        let cell = LayoutCell(name: "NONRECT", shapes: [shape(fixture.m1, 0, 0, 2, 2), shape(fixture.m2, 0, 0, 2, 2),
                                                       shape(fixture.cut, 0, 0, 2, 1), shape(fixture.cut, 0, 1, 1, 1)])
        #expect(throws: NativePEXCalculationError.unsupportedCutGeometry) { try network(cell) }
        let old = try fixture.technology().electricalModels![0], range = PEXDimensionRangeMeters(minimumMeters: 0.1e-6, maximumMeters: 0.2e-6)
        let via = PEXViaElectricalModel(viaName: "VIA1", cutLayerName: "C1", bottomLayerName: "M1", topLayerName: "M2",
            resistanceOhmsPerCut: old.vias[0].resistanceOhmsPerCut, cutWidthRange: range, cutHeightRange: range)
        #expect(throws: NativePEXCalculationError.electricalModel(.outOfRange(field: "C1.cutDimensions"))) {
            try network(LayoutCell(name: "WIDE", shapes: [shape(fixture.m1), shape(fixture.m2), shape(fixture.cut)]),
                        technology: technology(vias: [via]))
        }
    }

    @Test func coplanarVisibleEdgesUsePhysicalGapAndScreenFartherEdges() throws {
        for span: Int32 in [1_000, 250] {
            let two = try network(LayoutCell(name: "TWO", shapes: [shape(fixture.m1), shape(fixture.m1, 2)]), span: span)
            #expect(close(capacitance(two, .coplanar), 1e-16))
            let three = try network(LayoutCell(name: "THREE", shapes: [shape(fixture.m1), shape(fixture.m1, 2), shape(fixture.m1, 4)]), span: span)
            #expect(close(capacitance(three, .coplanar), 2e-16))
            #expect(three.capacitors.filter { $0.kind == .coplanar }.allSatisfy {
                abs(Int64(three.nodes[$0.nodeA].minXDatabaseUnits) - Int64(three.nodes[$0.nodeB!].minXDatabaseUnits)) < 4_000
            })
        }
    }

    @Test func plateAreaAndFacingPatchFringeAreInvariantUnderSubdivision() throws {
        let cell = LayoutCell(name: "PLATE", shapes: [shape(fixture.m1), shape(fixture.m2)])
        for span: Int32 in [1_000, 250] {
            let result = try network(cell, span: span)
            #expect(result.resistors.allSatisfy { $0.kind == .sheet })
            #expect(result.snapshot.components.count == 2)
            #expect(close(capacitance(result, .interlayer), 4.1e-16))
        }
    }

    @Test func intermediateMetalScreensDeeperPlatePairs() throws {
        let old = try fixture.technology().electricalModels![0]
        let m3 = LayoutLayerID(name: "M3", purpose: "drawing")
        let names = ["M1", "M2", "M3"]
        var pairs: [PEXCouplingElectricalModel] = []
        for i in names.indices { for j in i..<names.count {
            pairs.append(.init(firstLayerName: names[i], secondLayerName: names[j], areaFaradsPerSquareMeter: 1e-5,
                sidewallFarads: 1e-16, gapRange: old.couplings[0].gapRange))
        } }
        let tech = try technology(conductors: old.conductors + [conductor("M3", bottom: 4e-6)], couplings: pairs,
            stack: [TechnologyLayer(name: "M1", order: 0), TechnologyLayer(name: "C1", order: 1),
                    TechnologyLayer(name: "M2", order: 2), TechnologyLayer(name: "M3", order: 3)])
        var layoutTech = LayoutTechDatabase.standard()
        var thirdLayer = layoutTech.layers[1]; thirdLayer.id = m3
        layoutTech.layers.append(thirdLayer)
        let source = try fixture.snapshot(LayoutCell(name: "SHIELD", shapes: [shape(fixture.m1), shape(fixture.m2), shape(m3)]),
                                           tech: layoutTech, conductiveLayers: [fixture.m1, fixture.m2, m3])
        var bindings = fixture.bindings; bindings[m3] = "M3"
        let result = try RectilinearPEXCalculator().calculate(snapshot: source, technology: tech, corner: PEXCorner(id: "tt"),
            layerNames: bindings, maximumCellSpanDatabaseUnits: 250)
        #expect(close(capacitance(result, .interlayer), 8.2e-16))
        #expect(result.capacitors.filter { $0.kind == .interlayer }.allSatisfy {
            Set([result.nodes[$0.nodeA].layerName, result.nodes[$0.nodeB!].layerName]) != ["M1", "M3"]
        })
    }

    @Test func pinAcrossIslandsDoesNotAddResistorsOrChangeCapturedOpen() throws {
        let pin = LayoutPin(name: "P", position: .init(x: 2, y: 0.5), size: .init(width: 4, height: 1), layer: fixture.m1, netID: UUID())
        let result = try network(LayoutCell(name: "PIN", shapes: [shape(fixture.m1), shape(fixture.m1, 3)], pins: [pin]))
        #expect(result.nodes.count == 2 && result.resistors.isEmpty)
        #expect(result.pinContacts.count == 1 && result.pinContacts[0].nodeIndices.count == 2)
        #expect(result.snapshot.opens.count == 1 && result.snapshot.components.count == 2)
    }

    @Test func realShortAndFloatingMetalArePreservedWithoutInventingNets() throws {
        var first = shape(fixture.m1), last = shape(fixture.m1, 2)
        first.netID = UUID(); last.netID = UUID()
        let result = try network(LayoutCell(name: "SHORT", shapes: [first, shape(fixture.m1, 1), last, shape(fixture.m1, 5)]))
        #expect(result.snapshot.shortComponentIndices.count == 1 && result.snapshot.components.count == 2)
        #expect(result.snapshot.components.contains { $0.declaredNets.isEmpty })
        #expect(result.resistors.allSatisfy { result.nodes[$0.nodeA].componentIndex == result.nodes[$0.nodeB].componentIndex })
    }

    @Test func hierarchyRepeatedSourceIdentityRetainsSeparatePhysicalOperators() throws {
        let child = LayoutCell(name: "LEAF", shapes: [fixture.rect(0, 0, 2, 1)])
        let root = LayoutCell(name: "ROOT", instances: [LayoutInstance(cellID: child.id, name: "a"),
            LayoutInstance(cellID: child.id, name: "b", transform: .init(translation: .init(x: 4, y: 0)))])
        let source = try fixture.snapshot(root, children: [child])
        let result = try RectilinearPEXCalculator().calculate(snapshot: source, technology: fixture.technology(),
            corner: PEXCorner(id: "tt"), layerNames: fixture.bindings, maximumCellSpanDatabaseUnits: 1_000)
        #expect(result.nodes.count == 4 && result.resistors.count == 2 && result.snapshot.components.count == 2)
        #expect(close(capacitance(result, .ground), 1.6e-15))
        #expect(Set(result.snapshot.footprints.map(\.occurrenceIndex)) == [1, 2])
    }

    @Test func finitePositiveCoefficientUnderflowAndOverflowAreRejected() throws {
        let old = try fixture.technology().electricalModels![0]
        let tiny = try technology(conductors: [conductor(area: Double.leastNonzeroMagnitude, perimeter: 0), old.conductors[1]])
        #expect(throws: NativePEXCalculationError.numericFailure) {
            try network(LayoutCell(name: "UNDERFLOW", shapes: [shape(fixture.m1)]), technology: tiny)
        }
        let huge = try technology(conductors: [conductor(area: 0, perimeter: Double.greatestFiniteMagnitude), old.conductors[1]])
        #expect(throws: NativePEXCalculationError.numericFailure) {
            try network(LayoutCell(name: "OVERFLOW", shapes: [fixture.rect(0, 0, 2_000_000, 2_000_000)]), span: Int32.max, technology: huge)
        }
    }

    @Test func explicitZeroCoefficientsProduceNoCapacitors() throws {
        let old = try fixture.technology().electricalModels![0]
        let tech = try technology(conductors: [conductor(area: 0, perimeter: 0), conductor("M2", bottom: 2e-6, area: 0, perimeter: 0)],
            couplings: old.couplings.map { .init(firstLayerName: $0.firstLayerName, secondLayerName: $0.secondLayerName,
                areaFaradsPerSquareMeter: 0, sidewallFarads: 0, gapRange: $0.gapRange) })
        let result = try network(LayoutCell(name: "ZERO", shapes: [shape(fixture.m1), shape(fixture.m2), shape(fixture.m1, 3)]), technology: tech)
        #expect(result.capacitors.isEmpty && result.nodes.count == 3)
    }

    @Test func positiveFringeRatioUnderflowCannotBecomeDeclaredZero() throws {
        let old = try fixture.technology().electricalModels![0]
        let range = PEXDimensionRangeMeters(minimumMeters: 1e-250, maximumMeters: 1e200)
        let lower = conductor(area: 0, perimeter: 0, width: range, length: range)
        let upper = PEXConductorElectricalModel(layerName: "M2", bottomHeightMeters: 1e150,
            thicknessMeters: 1e135, resistivityOhmMeters: 1e133, groundAreaFaradsPerSquareMeter: 0,
            groundPerimeterFaradsPerMeter: 0, widthRange: range, lengthRange: range)
        let tech = try technology(conductors: [lower, upper], couplings: old.couplings.map {
            .init(firstLayerName: $0.firstLayerName, secondLayerName: $0.secondLayerName,
                  areaFaradsPerSquareMeter: 0, sidewallFarads: 1e100, gapRange: range)
        })
        let source = try fixture.snapshot(LayoutCell(name: "RATIO", shapes: [
            shape(fixture.m1, 0, 0, 1e-200, 1e-200), shape(fixture.m2, 0, 0, 1e-200, 1e-200)]),
            scale: DatabaseUnitScale(databaseUnitsPerMicrometer: 1e200))
        #expect(throws: NativePEXCalculationError.numericFailure) {
            try RectilinearPEXCalculator().calculate(snapshot: source, technology: tech, corner: PEXCorner(id: "tt"),
                layerNames: fixture.bindings, maximumCellSpanDatabaseUnits: 1)
        }
    }

    @Test func lateElementLimitPublishesNoNetwork() throws {
        var result: NativePEXNetwork?
        #expect(throws: NativePEXCalculationError.limitExceeded(.networkElements)) {
            result = try network(LayoutCell(name: "LIMIT", shapes: [fixture.rect(0, 0, 3, 1)]),
                                 limits: .init(maximumNetworkElements: 2))
        }
        #expect(result == nil)
    }

    @Test func cancellationDuringOperatorsPublishesNoNetwork() throws {
        let source = try fixture.snapshot(LayoutCell(name: "CANCEL", shapes: [fixture.rect(0, 0, 4, 4)]))
        let tech = try fixture.technology()
        var meshChecks = 0
        _ = try NativePEXMesh.build(snapshot: source, technology: tech, corner: PEXCorner(id: "tt"), layerNames: fixture.bindings,
            maximumCellSpanDatabaseUnits: 250, isCancelled: { meshChecks += 1; return false })
        let boundary = meshChecks + 500
        var checks = 0, output: NativePEXNetwork?
        #expect(throws: NativePEXCalculationError.cancelled) {
            output = try RectilinearPEXCalculator().calculate(snapshot: source, technology: tech, corner: PEXCorner(id: "tt"),
                layerNames: fixture.bindings, maximumCellSpanDatabaseUnits: 250, isCancelled: { checks += 1; return checks == boundary })
        }
        #expect(checks == boundary && output == nil)
    }

    @Test func deterministicRepeatedCalculationRetainsExactInputs() throws {
        let cell = LayoutCell(name: "DETERMINISTIC", shapes: [fixture.rect(0, 0, 2, 1), shape(fixture.m2)])
        let source = try fixture.snapshot(cell), tech = try fixture.technology()
        let calculator = RectilinearPEXCalculator()
        let a = try calculator.calculate(snapshot: source, technology: tech, corner: PEXCorner(id: "tt"),
            layerNames: fixture.bindings, maximumCellSpanDatabaseUnits: 250)
        let b = try calculator.calculate(snapshot: source, technology: tech, corner: PEXCorner(id: "tt"),
            layerNames: fixture.bindings, maximumCellSpanDatabaseUnits: 250)
        #expect(a.nodes == b.nodes && a.resistors == b.resistors && a.capacitors == b.capacitors && a.pinContacts == b.pinContacts)
        #expect(a.model == tech.electricalModels![0] && a.maximumCellSpanDatabaseUnits == 250)
        #expect(a.snapshot.footprints == source.footprints)
        #expect(close(a.metersPerDatabaseUnit, 1e-9))
    }
}
