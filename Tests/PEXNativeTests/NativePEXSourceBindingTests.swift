import Foundation
import LayoutCore
import LayoutIO
import LayoutTech
import LayoutVerify
import PEXCore
import Testing
@testable import PEXNative

@Suite("Durable native source-net bindings", .timeLimit(.minutes(1)))
struct NativePEXSourceBindingTests {
    @Test(arguments: ["occurrence", "cell", "missing", "ambiguous"])
    func sourceSelectorsRefuseWrongOrAmbiguousAuthority(scenario: String) throws {
        var source = declaredSource()
        if scenario == "ambiguous" { source.cells[0].nets.append(.init(name: "SIGNAL")) }
        let original = source
        let selector = NativePEXInputNetSelector.sourceDeclared(occurrenceIndex: scenario == "occurrence" ? 7 : 0,
            expectedCellName: scenario == "cell" ? "OTHER" : "TOP",
            sourceNetName: scenario == "missing" ? "MISSING" : "SIGNAL")
        let configuration = try configured(source: source, bindings: [.init(selector: selector, netName: .init("CANONICAL"))])
        let expected: NativePEXInputError
        switch scenario {
        case "occurrence": expected = .invalidNetOccurrence(7)
        case "cell": expected = .netCellMismatch(occurrenceIndex: 0, expected: "OTHER", actual: "TOP")
        case "missing": expected = .missingSourceNet(occurrenceIndex: 0, name: "MISSING")
        default: expected = .ambiguousSourceNet(occurrenceIndex: 0, name: "SIGNAL")
        }
        var prepared: NativePEXPreparedInput?
        #expect(throws: expected) {
            prepared = try LayoutPEXInputPreparer().prepare(document: source, topCell: "TOP", configuration: configuration)
        }
        #expect(prepared == nil && source == original)
    }

    @Test func supplementalSelectorRequiresItsExplicitConfigurationDeclaration() throws {
        let source = declaredSource(), id = UUID()
        #expect(throws: NativePEXInputError.undeclaredSupplementalNet(cell: "TOP", netID: id)) {
            try configured(source: source, bindings: [.init(selector: .supplemental(occurrenceIndex: 0,
                expectedCellName: "TOP", netID: id), netName: .init("CANONICAL"))])
        }
    }

    @Test func repeatedSourceCellNamesRemainOccurrenceQualified() throws {
        let fixture = NativePEXTestFixture(), technology = LayoutTechDatabase.standard()
        var child = declaredSource().cells[0]
        child.name = "CHILD"
        let top = LayoutCell(name: "TOP", instances: [.init(cellID: child.id, name: "U0"),
            .init(cellID: child.id, name: "U1", transform: .init(translation: .init(x: 3, y: 0)))])
        let source = LayoutDocument(name: "repeated-source", cells: [top, child], topCellID: top.id)
        let original = source
        let captured = try LayoutConnectivityExtractor().captureConductors(document: source, tech: technology,
            conductiveLayers: [fixture.m1, fixture.m2], cellID: top.id)
        let scale = captured.coordinateUnits.scale
        let extent = try #require(Int32(exactly: scale.databaseUnits(forMicrometers: 1)))
        let bindings: [NativePEXInputNetBinding] = (1...2).map { occurrence in
            .init(selector: .sourceDeclared(occurrenceIndex: occurrence, expectedCellName: "CHILD", sourceNetName: "SIGNAL"),
                netName: .init("U\(occurrence - 1)/SIGNAL"))
        }
        let electrodes: [NativePEXElectrodeBinding] = try (0..<2).map { index in
            .init(pinIndex: index, terminal: .init(netName: bindings[index].netName, nodeName: .init("A")),
                faces: [.init(side: .minX,
                    coordinate: try #require(Int32(exactly: scale.databaseUnits(forMicrometers: Double(index) * 3))),
                    begin: 0, end: extent)])
        }
        let configuration = try NativePEXConfiguration(layoutTechnology: technology,
            layers: [.init(layerID: fixture.m1, electricalName: "M1", isConductive: true),
                     .init(layerID: fixture.m2, electricalName: "M2", isConductive: true),
                     .init(layerID: fixture.cut, electricalName: "C1", isConductive: false)],
            supplementalPins: [], netBindings: bindings, electrodeBindings: electrodes,
            expectedCoordinateUnits: captured.coordinateUnits, maximumCellSpanDatabaseUnits: extent)
        let decoded = try JSONDecoder().decode(NativePEXConfiguration.self, from: JSONEncoder().encode(configuration))
        let prepared = try LayoutPEXInputPreparer().prepare(document: source, topCell: "TOP", configuration: decoded)
        #expect(prepared.netBindings.map(\.occurrenceIndex) == [1, 2])
        #expect(prepared.snapshot.pins.map { $0.declaredNet?.occurrenceIndex } == [1, 2])
        let projection = try project(prepared, technology: fixture.technology())
        #expect(Set(projection.ir.nets.map(\.name)) == Set(bindings.map(\.netName)))
        #expect(projection.electrodes.contacts.count == 2)
        #expect(source == original && decoded.supplementalPins.isEmpty)
    }

    @Test func distinctSelectorsCannotPublishTwoBindingsForOneCapturedReference() throws {
        let source = declaredSource(), original = source
        let net = try #require(source.cells[0].nets.first)
        let pin = LayoutPin(name: "B", position: .init(x: 0.5, y: 0.5), size: .init(width: 1, height: 1),
            layer: NativePEXTestFixture().m1, netID: net.id)
        let configuration = try configured(source: source, bindings: [
            .init(selector: .sourceDeclared(occurrenceIndex: 0, expectedCellName: "TOP", sourceNetName: "SIGNAL"), netName: .init("SOURCE")),
            .init(selector: .supplemental(occurrenceIndex: 0, expectedCellName: "TOP", netID: net.id), netName: .init("SUPPLEMENTAL"))],
            pins: [.init(cellName: "TOP", pin: pin)])
        #expect(throws: NativePEXInputError.duplicateResolvedNetBinding(occurrenceIndex: 0, netID: net.id)) {
            try LayoutPEXInputPreparer().prepare(document: source, topCell: "TOP", configuration: configuration)
        }
        #expect(source == original && source.cells[0].pins.count == 1)
    }

    @Test(arguments: [false, true])
    func resolvedSelectorsPreserveStrictProjectionCoverage(extra: Bool) throws {
        var source = declaredSource()
        let originalID = try #require(source.cells[0].nets.first?.id)
        let unused = LayoutNet(name: "UNUSED")
        if extra { source.cells[0].nets.append(unused) }
        let bindings: [NativePEXInputNetBinding] = extra ? [
            .init(selector: .sourceDeclared(occurrenceIndex: 0, expectedCellName: "TOP", sourceNetName: "SIGNAL"), netName: .init("SIGNAL")),
            .init(selector: .sourceDeclared(occurrenceIndex: 0, expectedCellName: "TOP", sourceNetName: "UNUSED"), netName: .init("UNUSED"))] : []
        let configuration = try configured(source: source, bindings: bindings, electrodes: true)
        let prepared = try LayoutPEXInputPreparer().prepare(document: source, topCell: "TOP", configuration: configuration)
        let expected: NativePEXProjectionError = extra ? .unknownBinding(occurrenceIndex: 0, netID: unused.id)
            : .missingBinding(occurrenceIndex: 0, netID: originalID)
        #expect(throws: expected) { try project(prepared, technology: NativePEXTestFixture().technology()) }
    }

    @Test func resolutionBudgetsAndCancellationFailWithoutPublishingPreparedState() throws {
        let binding = NativePEXInputNetBinding(selector: .sourceDeclared(occurrenceIndex: 0,
            expectedCellName: "TOP", sourceNetName: "SIGNAL"), netName: .init("SIGNAL"))
        var source = declaredSource()
        let base = try configured(source: source, bindings: [binding])
        source.cells[0].nets.append(.init(name: String(repeating: "unused", count: 256)))
        let original = source
        let bounded = try configured(source: source, bindings: [binding],
            maximumMetadataEntries: base.metadataEntriesUsed + 256)
        var published: NativePEXPreparedInput?
        #expect(throws: NativePEXInputError.metadataLimitExceeded) {
            published = try LayoutPEXInputPreparer().prepare(document: source, topCell: "TOP", configuration: bounded)
        }
        #expect(published == nil && source == original)

        let preparer = LayoutPEXInputPreparer()
        var completeVisits = 0
        _ = try preparer.prepare(document: source, topCell: "TOP", configuration: base,
            isCancelled: { completeVisits += 1; return false })
        var visits = 0
        #expect(throws: NativePEXInputError.cancelled) {
            published = try preparer.prepare(document: source, topCell: "TOP", configuration: base,
                isCancelled: { visits += 1; return visits == completeVisits })
        }
        #expect(published == nil && visits == completeVisits && source == original)
    }

    @Test(arguments: [LayoutFileFormat.gds, .oasis])
    func sameStandardBytesPreserveActualSourceNetProjection(format: LayoutFileFormat) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "native-source-binding-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Source-binding fixture cleanup failed: \(error)") }
        }
        let fixture = NativePEXTestFixture()
        let net = LayoutNet(name: "SIGNAL")
        let rectangle = LayoutRect(origin: .zero, size: .init(width: 1, height: 1))
        let metal = LayoutShape(layer: fixture.m1, netID: net.id, geometry: .rect(rectangle),
            properties: ["def.pin.name": "A"])
        let pin = LayoutPin(name: "A", position: rectangle.center, size: rectangle.size,
            layer: fixture.m1, netID: net.id)
        let cell = LayoutCell(name: "TOP", shapes: [metal], pins: [pin], nets: [net])
        let source = LayoutDocument(name: "source-binding", cells: [cell], topCellID: cell.id)
        let original = source
        let technology = LayoutTechDatabase.standard()
        let converter = MaskDataFormatConverter(tech: technology)
        let path = root.appending(path: format == .gds ? "source.gds" : "source.oas")
        try converter.exportDocument(source, to: path, format: format)
        let bytes = try Data(contentsOf: path)
        let first = try converter.importFromData(bytes, format: format)
        let captured = try LayoutConnectivityExtractor().captureConductors(document: first, tech: technology,
            conductiveLayers: [fixture.m1, fixture.m2], cellID: first.topCellID)
        let reference = try #require(captured.pins.first?.declaredNet)
        let extent = try #require(Int32(exactly: captured.coordinateUnits.scale.databaseUnits(forMicrometers: 1)))
        let configuration = try NativePEXConfiguration(layoutTechnology: technology,
            layers: [.init(layerID: fixture.m1, electricalName: "M1", isConductive: true),
                     .init(layerID: fixture.m2, electricalName: "M2", isConductive: true),
                     .init(layerID: fixture.cut, electricalName: "C1", isConductive: false)],
            supplementalPins: [], netBindings: [.init(selector: .sourceDeclared(occurrenceIndex: reference.occurrenceIndex,
                expectedCellName: "TOP", sourceNetName: "SIGNAL"), netName: .init("SIGNAL"))],
            electrodeBindings: [.init(pinIndex: 0,
                terminal: .init(netName: .init("SIGNAL"), nodeName: .init("A")),
                faces: [.init(side: .minX, coordinate: 0, begin: 0, end: extent)])],
            expectedCoordinateUnits: captured.coordinateUnits, maximumCellSpanDatabaseUnits: extent)
        let configurationBytes = try JSONEncoder().encode(configuration)
        #expect(!String(decoding: configurationBytes, as: UTF8.self).contains(reference.netID.uuidString))
        let decoded = try JSONDecoder().decode(NativePEXConfiguration.self, from: configurationBytes)
        let preparer = LayoutPEXInputPreparer()
        let firstPrepared = try preparer.prepare(document: first, topCell: "TOP", configuration: decoded)
        let firstProjection = try project(firstPrepared, technology: fixture.technology())
        #expect(firstProjection.ir.nets.map(\.name) == [.init("SIGNAL")])
        #expect(firstProjection.electrodes.ports.map(\.terminal)
            == [.init(netName: .init("SIGNAL"), nodeName: .init("A"))])

        let second = try converter.importFromData(bytes, format: format)
        let secondPrepared = try preparer.prepare(document: second, topCell: "TOP", configuration: decoded)
        let secondProjection = try project(secondPrepared, technology: fixture.technology())
        #expect(secondProjection.ir.nets.map(\.name) == [.init("SIGNAL")])
        #expect(secondProjection.electrodes.ports.map(\.terminal) == firstProjection.electrodes.ports.map(\.terminal))
        #expect(secondProjection.ir.nets.first?.totalGroundCapF == firstProjection.ir.nets.first?.totalGroundCapF)
        #expect(secondProjection.electrodes.contacts.count == 1)
        #expect(secondProjection.electrodes.contacts.allSatisfy { $0.ohms.isFinite && $0.ohms > 0 })
        #expect(first.cells.first?.pins.count == 1 && second.cells.first?.pins.count == 1)
        #expect(secondPrepared.snapshot.hierarchy.shapes == second.cells.flatMap(\.shapes))
        #expect(source == original && decoded.supplementalPins.isEmpty)
        #expect(try Data(contentsOf: path) == bytes)
    }

    private func project(_ prepared: NativePEXPreparedInput, technology: TechnologyIR) throws -> NativePEXProjection {
        let configuration = prepared.configuration
        let network = try RectilinearPEXCalculator().calculate(snapshot: prepared.snapshot, technology: technology,
            corner: .init(id: "tt"), layerNames: configuration.layerNames,
            maximumCellSpanDatabaseUnits: configuration.maximumCellSpanDatabaseUnits,
            limits: configuration.calculationLimits)
        let electrodes = try RectilinearPEXElectrodeBuilder().build(network: network,
            bindings: configuration.electrodeBindings, limits: configuration.electrodeLimits)
        return try CanonicalPEXProjector().project(electrodes: electrodes,
            netBindings: prepared.netBindings, limits: configuration.projectionLimits)
    }

    private func declaredSource() -> LayoutDocument {
        let fixture = NativePEXTestFixture(), net = LayoutNet(name: "SIGNAL")
        let rectangle = LayoutRect(origin: .zero, size: .init(width: 1, height: 1))
        let shape = LayoutShape(layer: fixture.m1, netID: net.id, geometry: .rect(rectangle))
        let pin = LayoutPin(name: "A", position: rectangle.center, size: rectangle.size, layer: fixture.m1, netID: net.id)
        let cell = LayoutCell(name: "TOP", shapes: [shape], pins: [pin], nets: [net])
        return .init(name: "declared", cells: [cell], topCellID: cell.id)
    }

    private func configured(source: LayoutDocument, bindings: [NativePEXInputNetBinding],
                            pins: [NativePEXPinDefinition] = [], electrodes: Bool = false,
                            maximumMetadataEntries: Int = 1_000_000) throws -> NativePEXConfiguration {
        let fixture = NativePEXTestFixture(), technology = LayoutTechDatabase.standard()
        let captured = try LayoutConnectivityExtractor().captureConductors(document: source, tech: technology,
            conductiveLayers: [fixture.m1, fixture.m2], cellID: source.topCellID)
        let extent = try #require(Int32(exactly: captured.coordinateUnits.scale.databaseUnits(forMicrometers: 1)))
        return try .init(layoutTechnology: technology,
            layers: [.init(layerID: fixture.m1, electricalName: "M1", isConductive: true),
                     .init(layerID: fixture.m2, electricalName: "M2", isConductive: true),
                     .init(layerID: fixture.cut, electricalName: "C1", isConductive: false)],
            supplementalPins: pins, netBindings: bindings,
            electrodeBindings: electrodes ? [.init(pinIndex: 0, terminal: .init(netName: .init("SIGNAL"), nodeName: .init("A")),
                faces: [.init(side: .minX, coordinate: 0, begin: 0, end: extent)])] : [],
            expectedCoordinateUnits: captured.coordinateUnits, maximumCellSpanDatabaseUnits: extent,
            maximumMetadataEntries: maximumMetadataEntries)
    }
}
