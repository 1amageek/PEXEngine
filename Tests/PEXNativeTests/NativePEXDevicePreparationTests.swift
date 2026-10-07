import Foundation
import CircuiteFoundation
import LayoutCore
import LayoutIO
import LayoutTech
import LayoutVerify
import PEXCore
import Testing
@testable import PEXNative

@Suite("Full material Device-owned native PEX", .timeLimit(.minutes(1)))
struct NativePEXDevicePreparationTests {
    private func layer(_ name: String) -> LayoutLayerID { .init(name: name, purpose: name == "CONTACT" || name == "VIA1" ? "cut" : "drawing") }
    private func shape(_ name: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> LayoutShape {
        .init(layer: layer(name), geometry: .rect(.init(origin: .init(x: x, y: y), size: .init(width: w, height: h))))
    }
    private func source() -> LayoutDocument {
        var shapes = [shape("ACTIVE", 0, 0, 4, 1), shape("ACTIVE", 0, 4, 4, 1),
            shape("POLY", 1.5, -1, 1, 7), shape("NIMP", -0.2, -0.2, 4.4, 1.4),
            shape("PIMP", -0.2, 3.8, 4.4, 1.4), shape("NWELL", -0.4, 3.6, 4.8, 1.8),
            shape("M1", 0, 0, 1, 1), shape("M1", 0, 4, 1, 1),
            shape("M1", 3, 0, 1, 5), shape("M1", 1.5, -1, 1, 0.5)]
        for y in [0.4, 4.4] { for x in [0.3, 3.3] { shapes.append(shape("CONTACT", x, y, 0.22, 0.22)) } }
        shapes.append(shape("CONTACT", 1.8, -0.8, 0.22, 0.22))
        let cell = LayoutCell(name: "INV", shapes: shapes)
        return LayoutDocument(name: "full-inverter", cells: [cell], topCellID: cell.id)
    }
    private func configuration(context: LayoutElectricalContext, fullMaterials: Bool = true) throws -> NativePEXConfiguration {
        let nets = (0..<4).map { UUID(uuidString: "00000000-0000-0000-0000-00000000010\($0)")! }
        let names = ["VSS", "VDD", "Y", "A"]
        let boxes = [(0.0, 0.0, 1.0, 1.0), (0.0, 4.0, 1.0, 1.0), (3.0, 0.0, 1.0, 5.0), (1.5, -1.0, 1.0, 0.5)]
        let bindings: [NativePEXLayerBinding] = ["ACTIVE", "POLY", "M1", "M2", "CONTACT", "VIA1"].map {
            .init(layerID: layer($0), electricalName: $0, isConductive: $0 != "CONTACT" && $0 != "VIA1" && (fullMaterials || $0 == "M1"))
        }
        let pins: [NativePEXPinDefinition] = boxes.enumerated().map { index, box in
            .init(cellName: "INV", pin: .init(name: names[index], position: .init(x: box.0 + box.2 / 2, y: box.1 + box.3 / 2),
                size: .init(width: box.2, height: box.3), layer: layer("M1"), netID: nets[index]))
        }
        let netBindings: [NativePEXNetBinding] = names.enumerated().map { .init(occurrenceIndex: 0, netID: nets[$0.offset], netName: .init($0.element)) }
        let electrodes: [NativePEXElectrodeBinding] = boxes.enumerated().map { index, box in
                .init(pinIndex: index, terminal: .init(netName: .init(names[index]), nodeName: .init(names[index])),
                    faces: [.init(side: .minX, coordinate: Int32(box.0 * 2000), begin: Int32(box.1 * 2000), end: Int32((box.1 + box.3) * 2000))])
        }
        return try .init(layoutTechnology: .sampleProcess(), layers: bindings, supplementalPins: pins,
            netBindings: netBindings, electrodeBindings: electrodes, expectedCoordinateUnits: LayoutUnits(scale: try .init(databaseUnitsPerMicrometer: 2000)), maximumCellSpanDatabaseUnits: 2000, electricalContext: context)
    }
    private func technology() throws -> TechnologyIR {
        let old = try NativePEXTestFixture().technology().electricalModels![0]
        let range = old.conductors[0].widthRange
        let conductors = ["ACTIVE", "POLY", "M1", "M2"].enumerated().map {
            PEXConductorElectricalModel(layerName: $0.element, bottomHeightMeters: Double($0.offset) * 2e-6,
                thicknessMeters: 1e-6, resistivityOhmMeters: 2e-8, groundAreaFaradsPerSquareMeter: 1e-4,
                groundPerimeterFaradsPerMeter: 1e-10, widthRange: range, lengthRange: range)
        }
        let vias = [("CONT_ACTIVE", "CONTACT", "ACTIVE", "M1"), ("CONT_POLY", "CONTACT", "POLY", "M1"), ("VIA1", "VIA1", "M1", "M2")].map {
            PEXViaElectricalModel(viaName: $0.0, cutLayerName: $0.1, bottomLayerName: $0.2, topLayerName: $0.3,
                resistanceOhmsPerCut: $0.0 == "CONT_POLY" ? 6 : 2, cutWidthRange: range, cutHeightRange: range)
        }
        var coupling: [PEXCouplingElectricalModel] = []
        for first in conductors.indices { for second in first..<conductors.count {
            coupling.append(.init(firstLayerName: conductors[first].layerName, secondLayerName: conductors[second].layerName,
                areaFaradsPerSquareMeter: 1e-5, sidewallFarads: 1e-16, gapRange: range))
        } }
        let model = PEXElectricalModel(law: .analyticalRectilinearV1, coplanarScreening: nil, processName: old.processName,
            cornerID: old.cornerID, temperatureKelvin: old.temperatureKelvin, voltageVolts: old.voltageVolts,
            parameters: [:], referenceNodeName: "0", calibrationArtifacts: old.calibrationArtifacts,
            conductors: conductors, vias: vias, couplings: coupling)
        return .init(processName: old.processName, stack: ["ACTIVE", "POLY", "CONTACT", "M1", "VIA1", "M2"].enumerated().map { .init(name: $0.element, order: $0.offset) },
            logicalToPhysicalLayerMap: [:], vias: vias.map { .init(name: $0.viaName, topLayer: $0.topLayerName, bottomLayer: $0.bottomLayerName) },
            defaultExtractionRules: .default, backendHints: [:], electricalModels: [model])
    }

    @Test func fullSourceTwoMOSFourRootPortsRunsActualPreparationCalculationElectrodesAndProjection() throws {
        let original = source()
        let config = try configuration(context: .deviceAwareMOS)
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(NativePEXConfiguration.self, from: encoded)
        #expect(decoded.electricalContext == .deviceAwareMOS)
        let prepared = try LayoutPEXInputPreparer().prepare(document: original, topCell: "INV", configuration: decoded)
        #expect(original.cells[0].pins.isEmpty && original.cells[0].shapes.count == 15)
        #expect(prepared.snapshot.hierarchy.shapes == original.cells[0].shapes)
        #expect(prepared.snapshot.electricalContext == .deviceAwareMOS)
        #expect(prepared.snapshot.conductiveLayers == decoded.conductiveLayers)
        #expect(prepared.snapshot.components.count == 4 && prepared.snapshot.pins.count == 4)
        #expect(prepared.snapshot.shortComponentIndices.isEmpty && prepared.snapshot.opens.isEmpty)
        let devices = try DeviceExtractor().extract(document: original, tech: config.layoutTechnology)
        #expect(devices.netlist.devices.count == 2)
        for device in devices.netlist.devices { #expect(device.terminals[.source] != device.terminals[.drain]) }
        let network = try RectilinearPEXCalculator().calculate(snapshot: prepared.snapshot, technology: technology(), corner: .init(id: "tt"),
            layerNames: config.layerNames, maximumCellSpanDatabaseUnits: config.maximumCellSpanDatabaseUnits, limits: config.calculationLimits)
        #expect(network.nodes.filter { $0.kind == .cut(viaName: "CONT_ACTIVE") }.count == 4)
        #expect(network.nodes.filter { $0.kind == .cut(viaName: "CONT_POLY") }.count == 1)
        let electrodes = try RectilinearPEXElectrodeBuilder().build(network: network, bindings: config.electrodeBindings, limits: config.electrodeLimits)
        let projection = try CanonicalPEXProjector().project(electrodes: electrodes, netBindings: config.netBindings, limits: config.projectionLimits)
        #expect(Set(projection.ir.nets.map(\.name)) == Set(config.netBindings.map(\.netName)))
        #expect(projection.ir.nets.flatMap(\.nodes).filter { $0.kind == .pin }.count == 4)
        #expect(projection.ir.elements.allSatisfy { $0.value.isFinite && $0.value > 0 })
        #expect(projection.ir.elements.filter { $0.kind == .resistor }.allSatisfy { $0.nodeA.netName == $0.nodeB?.netName })
        #expect(try JSONDecoder().decode(ParasiticIR.self, from: JSONEncoder().encode(projection.ir)) == projection.ir)
    }

    @Test func fullMaterialContextRejectsMetalOnlyDeclarationBeforePublication() throws {
        #expect(throws: NativePEXInputError.conductiveLayersMismatch) {
            try LayoutPEXInputPreparer().prepare(document: source(), topCell: "INV", configuration: configuration(context: .deviceAwareMOS, fullMaterials: false))
        }
    }

    @Test func geometricContextCannotSilentlyApplyDeviceSeparation() throws {
        let prepared = try LayoutPEXInputPreparer().prepare(document: source(), topCell: "INV", configuration: configuration(context: .geometric))
        #expect(prepared.snapshot.electricalContext == .geometric)
        #expect(prepared.snapshot.components.count == 2)
        #expect(!prepared.snapshot.shortComponentIndices.isEmpty)
    }

}
