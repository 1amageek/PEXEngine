import Foundation
import Testing
import CircuiteFoundation
import PEXCore
import LayoutCore
import LayoutTech
import LayoutVerify
import PEXNative

@Suite("Explicit single-plane source-law capacitance", .timeLimit(.minutes(1)))
struct NativePEXScreenedCapacitanceTests {
    private let layer = LayoutLayerID(name: "M1", purpose: "drawing")
    private let other = LayoutLayerID(name: "M2", purpose: "drawing")
    private let parameters = PEXCoplanarScreening(offsetMeters: 0.25e-6,
        interactionHaloMeters: 8e-6, groundFringeInverseMeters: 515_600)

    private func technology(screening: PEXCoplanarScreening? = nil,
                            gapRange: PEXDimensionRangeMeters = .init(minimumMeters: 0.5e-6, maximumMeters: 10),
                            sidewall: Double = 44e-18) throws -> TechnologyIR {
        // Exact retained Sky130A nominal source-deck identity from B85. This test
        // proves its declared algebra; retained identity does not qualify a process.
        let calibration = try ArtifactID(digest: .init(algorithm: .sha256,
            hexadecimalValue: "31287ea98453d1a4a0fe9e18f8e2a9a0aa411bea3e5eae9db3dd5e450bcd57c0"), byteCount: 168_522)
        let range = PEXDimensionRangeMeters(minimumMeters: 1e-9, maximumMeters: 10)
        let model = PEXElectricalModel(law: .singlePlaneCoplanarGroundV1,
            coplanarScreening: screening ?? parameters, processName: "source-law-fixture", cornerID: "nominal",
            temperatureKelvin: 298.15, voltageVolts: 1.8, parameters: [:], referenceNodeName: "0",
            calibrationArtifacts: [calibration], conductors: [.init(layerName: "M1", bottomHeightMeters: 1.3761e-6,
                thicknessMeters: 0.36e-6, resistivityOhmMeters: 4.5e-8,
                groundAreaFaradsPerSquareMeter: 25.78e-6, groundPerimeterFaradsPerMeter: 40.57e-12,
                widthRange: range, lengthRange: range)], vias: [],
            couplings: [.init(firstLayerName: "M1", secondLayerName: "M1", areaFaradsPerSquareMeter: 0,
                sidewallFarads: sidewall, gapRange: gapRange)])
        return .init(processName: model.processName, stack: [.init(name: "M1", order: 0)],
            logicalToPhysicalLayerMap: [:], vias: [], defaultExtractionRules: .default,
            backendHints: [:], electricalModels: [model])
    }

    private func strip(_ y: Double = 0, x: Double = 0, length: Double = 10,
                       net: UUID? = nil) -> LayoutShape {
        .init(layer: layer, netID: net, geometry: .rect(.init(origin: .init(x: x, y: y),
            size: .init(width: length, height: 1))))
    }

    private func prepared(_ shapes: [LayoutShape], scale: DatabaseUnitScale = .nanometerGrid,
                          spanMicrometers: Double = 1, net: UUID? = nil) throws -> NativePEXPreparedInput {
        let units = LayoutUnits(scale: scale)
        let layoutTech = LayoutTechDatabase(units: units, grid: 0.001, layers: [layer, other].enumerated().map {
            .init(id: $0.element, displayName: $0.element.name, gdsLayer: $0.offset + 1, gdsDatatype: 0,
                color: .init(red: 0.3, green: 0.5, blue: 0.7))
        }, vias: [], layerRules: [])
        let cell = LayoutCell(name: "SCREENED", shapes: shapes, nets: net.map { [.init(id: $0, name: "SIGNAL")] } ?? [])
        let document = LayoutDocument(name: "screened", units: units, cells: [cell], topCellID: cell.id)
        let configuration = try NativePEXConfiguration(layoutTechnology: layoutTech,
            layers: [.init(layerID: layer, electricalName: "M1", isConductive: true)],
            supplementalPins: [], netBindings: net.map { _ in [.init(selector: .sourceDeclared(occurrenceIndex: 0,
                expectedCellName: "SCREENED", sourceNetName: "SIGNAL"), netName: NetName("SIGNAL"))] } ?? [],
            electrodeBindings: [], expectedCoordinateUnits: units,
            maximumCellSpanDatabaseUnits: try #require(Int32(exactly: spanMicrometers * scale.databaseUnitsPerMicrometer)))
        let preparer: any NativePEXInputPreparing = LayoutPEXInputPreparer()
        return try preparer.prepare(document: document, topCell: cell.name, configuration: configuration, isCancelled: { false })
    }

    private func calculate(_ input: NativePEXPreparedInput, technology supplied: TechnologyIR? = nil,
                           limits: NativePEXCalculationLimits = .default, cancelled: () -> Bool = { false }) throws -> NativePEXNetwork {
        let calculator: any NativePEXCalculating = RectilinearPEXCalculator()
        return try calculator.calculate(snapshot: input.snapshot, technology: supplied ?? technology(),
            corner: .init(id: "nominal"), layerNames: input.configuration.layerNames,
            maximumCellSpanDatabaseUnits: input.configuration.maximumCellSpanDatabaseUnits,
            limits: limits, isCancelled: cancelled)
    }

    private func sum(_ result: NativePEXNetwork, _ kind: NativePEXNetwork.Capacitor.Kind) -> Double {
        result.capacitors.filter { $0.kind == kind }.reduce(0) { $0 + $1.farads }
    }

    private func expectNear(_ result: NativePEXNetwork, _ kind: NativePEXNetwork.Capacitor.Kind,
                            _ expected: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        let operations = 16 * result.nodes.count + 4 * result.capacitors.count
        let budget = Double(operations) * Double.ulpOfOne * abs(expected)
        #expect(abs(sum(result, kind) - expected) <= budget, sourceLocation: sourceLocation)
    }

    @Test(arguments: [1.0, 2.0])
    func bothSourceLawObservablesMatchRetainedTwoGapOracle(gap: Double) throws {
        let result = try calculate(prepared([strip(), strip(1 + gap)]))
        // Independent source-law recomputation of B85 retained raw Magic outputs,
        // before their decimal quantization; no coefficient is fitted to those outputs.
        expectNear(result, .coplanar, gap == 1 ? 0.352e-15 : 0.19555555555555554e-15)
        expectNear(result, .ground, gap == 1 ? 1.7351773365927766e-15 : 1.9029009830185012e-15)
        #expect(result.capacitors.allSatisfy { $0.farads > 0 && $0.farads.isFinite })
        #expect(result.capacitors.allSatisfy { $0.kind != .interlayer })
        let loss = 2.30068e-15 - sum(result, .ground)
        #expect(loss > 0 && abs(loss - sum(result, .coplanar)) > 1e-17)
    }

    @Test func isolatedStripRetainsAllGroundAreaAndPerimeter() throws {
        let result = try calculate(prepared([strip()]))
        expectNear(result, .ground, 1.15034e-15)
        #expect(sum(result, .coplanar) == 0)
    }

    @Test(arguments: [7.999, 8.0, 9.0])
    func strictHaloBoundaryIsDistinctFromGapApplicability(gap: Double) throws {
        let result = try calculate(prepared([strip(), strip(1 + gap)]), technology: technology(
            gapRange: .init(minimumMeters: 0.5e-6, maximumMeters: gap < 8 ? 8e-6 : 2e-6)))
        if gap < 8 {
            #expect(sum(result, .coplanar) > 0 && sum(result, .ground) < 2.30068e-15)
        } else {
            expectNear(result, .ground, 2.30068e-15)
            #expect(sum(result, .coplanar) == 0)
        }
    }

    @Test func nearestNeighborPartitionDoesNotCoupleAcrossTheMiddleStrip() throws {
        let result = try calculate(prepared([strip(), strip(2), strip(4)]))
        expectNear(result, .coplanar, 0.704e-15)
        expectNear(result, .ground, 2.320014673185553e-15)
        #expect(result.capacitors.filter { $0.kind == .coplanar }.allSatisfy {
            let a = result.nodes[$0.nodeA], b = result.nodes[$0.nodeB!]
            let distance = abs(Double(a.minYDatabaseUnits) - Double(b.minYDatabaseUnits)) * result.metersPerDatabaseUnit
            return distance <= (2e-6).nextUp
        })
    }

    @Test func partialFacingEdgeConsumesOnlyItsOwnLength() throws {
        let result = try calculate(prepared([strip(), strip(2, x: 3, length: 4)]))
        expectNear(result, .coplanar, 0.1408e-15)
        expectNear(result, .ground, 1.4329589346371108e-15)
        let otherSide = try calculate(prepared([strip(), strip(-2, x: 3, length: 4)]))
        expectNear(otherSide, .ground, sum(result, .ground))
        expectNear(otherSide, .coplanar, sum(result, .coplanar))
    }

    @Test func refinementAndCoordinateUnitsPreserveThePhysicalLaw() throws {
        for scale in [DatabaseUnitScale.nanometerGrid, try .init(databaseUnitsPerMicrometer: 2_000)] {
            for span in [1.0, 0.25, 10.0] {
                let result = try calculate(prepared([strip(), strip(2)], scale: scale, spanMicrometers: span))
                expectNear(result, .coplanar, 0.352e-15)
                expectNear(result, .ground, 1.7351773365927766e-15)
            }
        }
    }

    @Test func sameNetComponentsRetainDistinctNumericNodesAndCanonicalOperators() throws {
        let net = UUID()
        let input = try prepared([strip(net: net), strip(2, net: net)], net: net)
        let result = try calculate(input)
        let electrodes = try RectilinearPEXElectrodeBuilder().build(network: result, bindings: [])
        let projection = try CanonicalPEXProjector().project(electrodes: electrodes,
            netBindings: input.netBindings, limits: .default, isCancelled: { false })
        #expect(projection.ir.nets.count == 1 && result.snapshot.components.count == 2)
        #expect(projection.numericNodeReferences.count == result.nodes.count)
        let pairs = projection.ir.elements.filter { $0.kind == .coupling }
        #expect(pairs.count == result.capacitors.filter { $0.kind == .coplanar }.count)
        #expect(pairs.allSatisfy { $0.nodeA.netName == $0.nodeB?.netName && $0.nodeA != $0.nodeB })
        #expect(result.resistors.allSatisfy {
            result.nodes[$0.nodeA].componentIndex == result.nodes[$0.nodeB].componentIndex
        })
        #expect(projection.ir.metadata["nativeLaw"] == "singlePlaneCoplanarGroundV1")
        #expect(projection.ir.elements.filter { $0.kind == .coupling }.reduce(0) { $0 + $1.value } == sum(result, .coplanar))
    }

    @Test func referenceIncludedMatrixPreservesChargeAndPassivity() throws {
        let result = try calculate(prepared([strip(), strip(2)], spanMicrometers: 10))
        let reference = result.nodes.count, count = reference + 1
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
        for edge in result.capacitors {
            let a = edge.nodeA, b = edge.nodeB ?? reference
            matrix[a][a] += edge.farads; matrix[b][b] += edge.farads
            matrix[a][b] -= edge.farads; matrix[b][a] -= edge.farads
        }
        let magnitude = result.capacitors.reduce(0) { $0 + $1.farads }
        for row in matrix {
            #expect(abs(row.reduce(0, +)) <= Double(4 * result.capacitors.count) * Double.ulpOfOne * magnitude)
        }
        for i in 0..<count { for j in 0..<count { #expect(matrix[i][j] == matrix[j][i]) } }
        for voltages in [[1.0, 0.0, 0.0], [1.0, 1.0, 0.0], [-1.0, 2.0, 0.0]] {
            var energy = 0.0
            for i in 0..<count { for j in 0..<count { energy += 0.5 * voltages[i] * matrix[i][j] * voltages[j] } }
            #expect(energy >= 0)
        }
    }

    @Test func unselectedSourceLayerCannotDisappearFromLawAdmission() throws {
        var unselected = strip(2); unselected.layer = other
        let input = try prepared([strip(), unselected])
        #expect(input.snapshot.footprints.allSatisfy { $0.layer == layer })
        #expect(input.snapshot.hierarchy.shapes.contains { $0.layer == other })
        #expect(throws: NativePEXCalculationError.unsupportedSourceLayer(other)) { try calculate(input) }
    }

    @Test func inHaloOutOfRangeGapIsRejectedWithoutExtrapolation() throws {
        let input = try prepared([strip(), strip(4)])
        #expect(throws: NativePEXCalculationError.electricalModel(.outOfRange(field: "M1.coplanarGap"))) {
            try calculate(input, technology: technology(gapRange: .init(minimumMeters: 0.5e-6, maximumMeters: 2e-6)))
        }
    }

    @Test func reachableViaInventoryCannotDisappearFromTheSinglePlaneLaw() throws {
        let fixture = NativePEXTestFixture()
        let cell = LayoutCell(name: "VIA", vias: [LayoutVia(viaDefinitionID: "VIA1", position: .zero)])
        let snapshot = try fixture.snapshot(cell)
        #expect(snapshot.hierarchy.vias.count == 1)
        let calculator: any NativePEXCalculating = RectilinearPEXCalculator()
        #expect(throws: NativePEXCalculationError.unsupportedSourceVias) {
            try calculator.calculate(snapshot: snapshot, technology: technology(), corner: .init(id: "nominal"),
                layerNames: [layer: "M1"], maximumCellSpanDatabaseUnits: 1_000,
                limits: .default, isCancelled: { false })
        }
    }

    @Test func positivePhysicalTermsCannotSilentlyUnderflowOrOverflow() throws {
        let input = try prepared([strip(), strip(2)])
        #expect(throws: NativePEXCalculationError.numericFailure) {
            try calculate(input, technology: technology(screening: .init(offsetMeters: Double.greatestFiniteMagnitude,
                interactionHaloMeters: 8e-6, groundFringeInverseMeters: 515_600)))
        }
        #expect(throws: NativePEXCalculationError.numericFailure) {
            try calculate(input, technology: technology(screening: .init(offsetMeters: 0.25e-6,
                interactionHaloMeters: 8e-6, groundFringeInverseMeters: Double.leastNonzeroMagnitude)))
        }
        let far = try prepared([strip(), strip(2_000_001)], spanMicrometers: 10)
        #expect(throws: NativePEXCalculationError.numericFailure) {
            try calculate(far, technology: technology(screening: .init(offsetMeters: 0.25e-6,
                interactionHaloMeters: 3, groundFringeInverseMeters: Double.greatestFiniteMagnitude)))
        }
    }

    @Test func explicitZeroMultiplierIsMathematicalFullFringeShielding() throws {
        let result = try calculate(prepared([strip(), strip(2)]), technology: technology(screening: .init(
            offsetMeters: 0, interactionHaloMeters: 8e-6, groundFringeInverseMeters: 0)))
        expectNear(result, .coplanar, 0.44e-15)
        expectNear(result, .ground, 1.48928e-15)
    }

    @Test func workMeshAndLateElementBudgetsFailAtomically() throws {
        let input = try prepared([strip(), strip(2)], spanMicrometers: 10)
        for (limits, resource) in [
            (NativePEXCalculationLimits(maximumWorkVisits: 0), NativePEXCalculationError.Resource.workVisits),
            (.init(maximumMeshCells: 1), .meshCells), (.init(maximumNetworkElements: 2), .networkElements),
        ] {
            #expect(throws: NativePEXCalculationError.limitExceeded(resource)) { try calculate(input, limits: limits) }
        }
    }

    @Test func earlyAndLateCancellationPublishNoNetwork() throws {
        let input = try prepared([strip(), strip(2)])
        #expect(throws: NativePEXCalculationError.cancelled) { try calculate(input, cancelled: { true }) }
        var visits = 0
        _ = try calculate(input, cancelled: { visits += 1; return false })
        let finalVisit = visits
        var seen = 0
        #expect(throws: NativePEXCalculationError.cancelled) {
            try calculate(input, cancelled: { seen += 1; return seen >= finalVisit })
        }
    }
}
