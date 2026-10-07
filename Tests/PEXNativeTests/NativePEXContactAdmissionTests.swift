import Foundation
import LayoutCore
import LayoutTech
import LayoutVerify
import PEXCore
import Testing
@testable import PEXNative

@Suite("Native PEX selected cut contact admission", .timeLimit(.minutes(1)))
struct NativePEXContactAdmissionTests {
    private let fixture = NativePEXTestFixture()
    private var poly: LayoutLayerID { .init(name: "POLY", purpose: "drawing") }

    private func input(selectPoly: Bool, polyX: Double = 0, primaryPoly: Bool = false, alternateModels: Bool = false) throws
        -> (NativePEXPreparedInput, TechnologyIR) {
        var layout = LayoutTechDatabase.standard()
        var polyLayer = layout.layers[0]
        polyLayer.id = poly
        polyLayer.gdsLayer = 4
        layout.layers.append(polyLayer)
        let via = layout.vias[0]
        layout.vias = []
        let contactBottoms = selectPoly ? [fixture.m1, poly] : [fixture.m1]
        layout.contacts = contactBottoms.enumerated().map {
            LayoutContactDefinition(id: "CONTACT\($0.offset)", cutLayer: fixture.cut,
                bottomLayer: $0.element, topLayer: fixture.m2, cutSize: via.cutSize,
                enclosure: via.enclosure, cutSpacing: via.cutSpacing)
        }
        var bindings = fixture.bindings.map {
            NativePEXLayerBinding(layerID: $0.key, electricalName: $0.value,
                                  isConductive: $0.key != fixture.cut)
        }
        if selectPoly { bindings.append(.init(layerID: poly, electricalName: "POLY", isConductive: true)) }
        let configuration = try NativePEXConfiguration(layoutTechnology: layout, layers: bindings,
            supplementalPins: [], netBindings: [], electrodeBindings: [], expectedCoordinateUnits: .defaultUnits,
            maximumCellSpanDatabaseUnits: 1000)
        let cell = LayoutCell(name: "CONTACT", shapes: [fixture.m1, fixture.m2, fixture.cut, poly].map {
            LayoutShape(layer: $0, geometry: .rect(.init(origin: .init(x: $0 == poly ? polyX : ($0 == fixture.m1 && primaryPoly ? 1 : 0), y: 0),
                                                        size: .init(width: 1, height: 1))))
        })
        let document = LayoutDocument(name: "contact", cells: [cell], topCellID: cell.id)
        let prepared = try LayoutPEXInputPreparer().prepare(document: document, topCell: "CONTACT", configuration: configuration)
        let original = try fixture.technology()
        guard selectPoly else { return (prepared, original) }
        let source = try #require(original.electricalModels?.first)
        let conductors = ["POLY", "M1", "M2"].enumerated().map {
            PEXConductorElectricalModel(layerName: $0.element, bottomHeightMeters: Double($0.offset) * 2e-6,
                thicknessMeters: 1e-6, resistivityOhmMeters: 2e-8, groundAreaFaradsPerSquareMeter: 1e-4,
                groundPerimeterFaradsPerMeter: 1e-10, widthRange: source.conductors[0].widthRange,
                lengthRange: source.conductors[0].lengthRange)
        }
        var couplings: [PEXCouplingElectricalModel] = []
        for first in conductors.indices { for second in first..<conductors.count {
            couplings.append(.init(firstLayerName: conductors[first].layerName,
                secondLayerName: conductors[second].layerName, areaFaradsPerSquareMeter: 1e-5,
                sidewallFarads: 1e-16, gapRange: source.couplings[0].gapRange))
        } }
        let alternatives = alternateModels ? [PEXViaElectricalModel(viaName: "POLY_CONTACT", cutLayerName: "C1",
            bottomLayerName: "POLY", topLayerName: "M2", resistanceOhmsPerCut: 6,
            cutWidthRange: source.vias[0].cutWidthRange, cutHeightRange: source.vias[0].cutHeightRange)] : []
        let model = PEXElectricalModel(law: source.law, coplanarScreening: nil, processName: source.processName, cornerID: source.cornerID,
            temperatureKelvin: source.temperatureKelvin, voltageVolts: source.voltageVolts,
            parameters: source.parameters, referenceNodeName: source.referenceNodeName,
            calibrationArtifacts: source.calibrationArtifacts, conductors: conductors,
            vias: source.vias + alternatives, couplings: couplings)
        let technology = TechnologyIR(processName: original.processName,
            stack: ["POLY", "M1", "C1", "M2"].enumerated().map { TechnologyLayer(name: $0.element, order: $0.offset) },
            logicalToPhysicalLayerMap: [:], vias: original.vias + (alternateModels ? [.init(name: "POLY_CONTACT", topLayer: "M2", bottomLayer: "POLY")] : []), defaultExtractionRules: original.defaultExtractionRules,
            backendHints: [:], electricalModels: [model])
        return (prepared, technology)
    }

    private func calculate(_ prepared: NativePEXPreparedInput, technology: TechnologyIR) throws -> NativePEXNetwork {
        try RectilinearPEXCalculator().calculate(snapshot: prepared.snapshot, technology: technology,
            corner: PEXCorner(id: "tt"), layerNames: prepared.configuration.layerNames,
            maximumCellSpanDatabaseUnits: prepared.configuration.maximumCellSpanDatabaseUnits)
    }

    private func cutAndMaterial(_ snapshot: LayoutConductorSnapshot, material: LayoutLayerID) throws -> Bool {
        let cut = try #require(snapshot.footprints.firstIndex { $0.isCut })
        let conductor = try #require(snapshot.footprints.firstIndex { $0.layer == material })
        return try snapshot.hasElectricalContact(footprintAt: cut, with: snapshot, footprintAt: conductor)
    }

    @Test(arguments: [false, true])
    func sameSizeRawCutChoosesActualCompletePair(primaryPoly: Bool) throws {
        let (prepared, technology) = try input(selectPoly: true, polyX: primaryPoly ? 0 : 1,
            primaryPoly: primaryPoly, alternateModels: true)
        #expect(try cutAndMaterial(prepared.snapshot, material: poly) == primaryPoly)
        #expect(try cutAndMaterial(prepared.snapshot, material: fixture.m1) != primaryPoly)
        let network = try calculate(prepared, technology: technology)
        #expect(network.resistors.count == 2)
        #expect(network.resistors.allSatisfy { abs($0.ohms - (primaryPoly ? 3 : 1)) < 1e-12 })
        #expect(network.nodes.contains { $0.kind == .cut(viaName: primaryPoly ? "POLY_CONTACT" : "VIA1") })
    }

    @Test func selectedMetalOnlyKeepsAnalyticalUniqueCutRC() throws {
        let (prepared, technology) = try input(selectPoly: false)
        #expect(prepared.configuration.conductiveLayers == [fixture.m1, fixture.m2])
        #expect(prepared.snapshot.conductiveLayers == prepared.configuration.conductiveLayers)
        #expect(!prepared.snapshot.footprints.contains { $0.layer == poly })
        #expect(try cutAndMaterial(prepared.snapshot, material: fixture.m1))
        #expect(try cutAndMaterial(prepared.snapshot, material: fixture.m2))
        let network = try calculate(prepared, technology: technology)
        #expect(network.nodes.count == 3 && network.resistors.count == 2)
        #expect(network.resistors.allSatisfy { $0.kind == .cut && abs($0.ohms - 1) < 1e-12 })
        #expect(abs(network.capacitors.filter { $0.kind == .ground }.reduce(0) { $0 + $1.farads } - 1e-15) < 1e-27)
    }

    @Test func actualSelectedAdditionalBottomContactFailsWithoutNetwork() throws {
        let (prepared, technology) = try input(selectPoly: true)
        #expect(prepared.snapshot.conductiveLayers == [poly, fixture.m1, fixture.m2])
        #expect(prepared.snapshot.components.count == 1)
        #expect(try cutAndMaterial(prepared.snapshot, material: poly))
        var output: NativePEXNetwork?
        #expect(throws: NativePEXCalculationError.ambiguousCutModel) {
            output = try calculate(prepared, technology: technology)
        }
        #expect(output == nil)
    }

    @Test func selectedEdgeOnlyMaterialDoesNotBecomeCutElectrode() throws {
        let (prepared, technology) = try input(selectPoly: true, polyX: 1)
        #expect(prepared.snapshot.components.count == 2)
        #expect(try !cutAndMaterial(prepared.snapshot, material: poly))
        let network = try calculate(prepared, technology: technology)
        #expect(network.nodes.count == 4 && network.resistors.count == 2)
        #expect(network.resistors.allSatisfy { $0.kind == .cut && abs($0.ohms - 1) < 1e-12 })
        #expect(network.snapshot.components.count == 2)
    }
}
