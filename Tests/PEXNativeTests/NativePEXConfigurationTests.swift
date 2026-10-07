import Foundation
import Testing
import LayoutCore
import LayoutTech
import LayoutIO
import LayoutVerify
import PEXCore
@testable import PEXNative

@Suite("Admitted native configuration and actual input preparation", .timeLimit(.minutes(1)))
struct NativePEXConfigurationTests {
    private let fixture = NativePEXTestFixture()

    @Test(arguments: [LayoutFileFormat.gds, .oasis])
    func decodedConfigurationConsumesStandardGeometryAndPreservesAnalyticalOperators(format: LayoutFileFormat) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "native-schema-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record("Fixture cleanup failed: \(error)") } }
        let source = document(), original = source
        let config = try configuration()
        let converter = MaskDataFormatConverter(tech: config.layoutTechnology)
        let path = root.appending(path: format == .gds ? "geometry.gds" : "geometry.oas")
        try converter.exportDocument(source, to: path, format: format)
        let imported = try converter.importDocument(from: path, format: format)
        #expect(imported.cells.first?.pins.isEmpty == true)
        #expect(imported.cells.first?.labels.count == 1)
        let data = try JSONEncoder().encode(config)
        #expect(!String(decoding: data, as: UTF8.self).contains("metadataEntriesUsed"))
        let decoded = try JSONDecoder().decode(NativePEXConfiguration.self, from: data)
        #expect(decoded == config && decoded.captureLimits.geometryLimits == config.captureLimits.geometryLimits)
        let prepared = try LayoutPEXInputPreparer().prepare(document: imported, topCell: "TOP", configuration: decoded)
        #expect(prepared.snapshot.hierarchy.shapes.count == 1 && prepared.snapshot.pins.count == 2)
        #expect(prepared.snapshot.coordinateUnits.scale.databaseUnitsPerMicrometer == 2000)
        #expect(prepared.snapshot.hierarchy.units.scale.databaseUnitsPerMicrometer == 1000)
        #expect(prepared.snapshot.hierarchy.rootCellID == imported.cells.first?.id)
        let graph = try project(prepared)
        #expect(graph.electrodes.network.nodes.count == 1 && graph.electrodes.network.resistors.isEmpty)
        #expect(graph.electrodes.contacts.count == 2)
        #expect(abs(graph.electrodes.contacts.reduce(0) { $0 + $1.ohms } - 0.02) < 1e-14)
        #expect(abs(graph.ir.nets.reduce(0) { $0 + $1.totalGroundCapF } - 5e-16) < 1e-28)
        #expect(graph.ir.nets.flatMap(\.nodes).filter { $0.kind == .pin }.map(\.name).sorted { $0.value < $1.value } == [NodeName("A"), NodeName("B")])
        #expect(source == original && source.cells.first?.pins.isEmpty == true)
        #expect(imported.cells.first?.pins.isEmpty == true)
    }

    @Test func repeatedCellPinsAreAppliedOnceAndRemainOccurrenceExact() throws {
        let base = try configuration()
        var schema = try json(base)
        var pins = try #require(schema["supplementalPins"] as? [[String: Any]])
        for index in pins.indices { pins[index]["cellName"] = "CHILD" }
        schema["supplementalPins"] = pins
        let netID = try #require(base.supplementalPins.first?.pin.netID)
        let bindings = [NativePEXInputNetBinding(selector: .supplemental(occurrenceIndex: 1, expectedCellName: "CHILD", netID: netID), netName: NetName("U0/SIGNAL")),
                        NativePEXInputNetBinding(selector: .supplemental(occurrenceIndex: 2, expectedCellName: "CHILD", netID: netID), netName: NetName("U1/SIGNAL"))]
        let electrodes = (0..<4).map { index in
            NativePEXElectrodeBinding(pinIndex: index,
                terminal: .init(netName: NetName("U\(index / 2)/SIGNAL"), nodeName: NodeName(index % 2 == 0 ? "A" : "B")),
                faces: [.init(side: index % 2 == 0 ? .minX : .maxX,
                              coordinate: Int32((index / 2) * 6000 + (index % 2) * 2000), begin: 0, end: 2000)])
        }
        schema["netBindings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bindings))
        schema["electrodeBindings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(electrodes))
        for (owner, field, value) in [("calculationLimits", "maximumMeshCells", 2), ("electrodeLimits", "maximumContacts", 4), ("projectionLimits", "maximumNodes", 6)] {
            var limits = try #require(schema[owner] as? [String: Any]); limits[field] = value; schema[owner] = limits
        }
        let config = try decode(schema)
        let child = LayoutCell(name: "CHILD", shapes: [fixture.rect(0, 0, 1, 1)])
        let top = LayoutCell(name: "TOP", instances: [LayoutInstance(cellID: child.id, name: "U0"),
            LayoutInstance(cellID: child.id, name: "U1", transform: .init(translation: .init(x: 3, y: 0)))])
        let source = LayoutDocument(name: "repeated", cells: [top, child], topCellID: top.id)
        let prepared = try LayoutPEXInputPreparer().prepare(document: source, topCell: "TOP", configuration: config)
        #expect(prepared.snapshot.pins.count == 4 && prepared.snapshot.components.count == 2)
        #expect(prepared.snapshot.pins.map { $0.declaredNet?.occurrenceIndex } == [1, 1, 2, 2])
        #expect(source.cells[1].pins.isEmpty)
        let graph = try project(prepared)
        #expect(Set(graph.ir.nets.map(\.name)) == Set(bindings.map(\.netName)))
        #expect(Set(graph.electrodes.ports.map(\.terminal)) == Set(electrodes.map(\.terminal)))
        #expect(graph.ir.elements.filter { $0.kind == .resistor }.allSatisfy { $0.nodeA.netName == $0.nodeB?.netName })
    }

    @Test func pinBoundsMustRemainRepresentableBeforeGeometryCapture() throws {
        let base = try configuration()
        for extremePosition in [false, true] {
            var first = base.supplementalPins[0].pin
            if extremePosition { first.position.x = .greatestFiniteMagnitude; first.size.width = 1 }
            else { first.size.width = .leastNonzeroMagnitude }
            let pins = [NativePEXPinDefinition(cellName: "TOP", pin: first), base.supplementalPins[1]]
            #expect(throws: NativePEXInputError.self) { try configuration(pins: pins) }
        }
    }

    @Test func everyCaptureLimitIsForwardedWithoutSubstitution() throws {
        let values = NativePEXCaptureLimits(maximumOccurrences: 11, maximumObjects: 12, maximumGeometryPoints: 13,
            maximumDepth: 14, maximumInputEntries: 15, maximumEdgeProbes: 16, maximumOutputBands: 17,
            maximumTechnologyRecords: 18, maximumFootprints: 19, maximumContactProbes: 20)
        let decoded = try JSONDecoder().decode(NativePEXCaptureLimits.self, from: JSONEncoder().encode(values))
        let actual = decoded.geometryLimits
        #expect([actual.hierarchy.maximumOccurrences, actual.hierarchy.maximumObjects, actual.hierarchy.maximumGeometryPoints,
            actual.hierarchy.maximumDepth, actual.decomposition.maximumInputEntries, actual.decomposition.maximumEdgeProbes,
            actual.decomposition.maximumOutputBands, actual.maximumTechnologyRecords, actual.maximumFootprints,
            actual.maximumContactProbes] == Array(11...20))
        #expect(NativePEXCaptureLimits().geometryLimits == .default)
    }

    @Test func decoderRepeatsStructuralAndEveryLowerLimitAdmission() throws {
        let valid = try json(configuration())
        for (field, value) in [("version", 4), ("maximumCellSpanDatabaseUnits", 0), ("maximumMetadataEntries", 1)] {
            var changed = valid; changed[field] = value
            #expect(throws: NativePEXInputError.self) { try decode(changed) }
        }
        for field in ["layers", "supplementalPins", "netBindings", "electrodeBindings"] {
            var changed = valid, items = try #require(changed[field] as? [[String: Any]])
            items.append(try #require(items.first)); changed[field] = items
            #expect(throws: NativePEXInputError.self) { try decode(changed) }
        }
        for owner in ["captureLimits", "calculationLimits", "electrodeLimits", "projectionLimits"] {
            let limits = try #require(valid[owner] as? [String: Any])
            for field in limits.keys {
                var changed = valid, bad = limits; bad[field] = -1; changed[owner] = bad
                #expect(throws: NativePEXInputError.self) { try decode(changed) }
            }
        }
        var changed = valid, bindings = try #require(valid["layers"] as? [[String: Any]])
        bindings[0]["layerID"] = ["name": "UNKNOWN", "purpose": "drawing"]; changed["layers"] = bindings
        #expect(throws: NativePEXInputError.self) { try decode(changed) }
        changed = valid
        var electrodes = try #require(changed["electrodeBindings"] as? [[String: Any]])
        var faces = try #require(electrodes[0]["faces"] as? [[String: Any]]); faces[0]["end"] = 0
        electrodes[0]["faces"] = faces; changed["electrodeBindings"] = electrodes
        #expect(throws: NativePEXInputError.self) { try decode(changed) }
        changed = valid
        var pins = try #require(changed["supplementalPins"] as? [[String: Any]])
        var pin = try #require(pins[0]["pin"] as? [String: Any]); pin["size"] = ["width": 0, "height": 1]
        pins[0]["pin"] = pin; changed["supplementalPins"] = pins
        #expect(throws: NativePEXInputError.self) { try decode(changed) }
    }

    @Test func requiredContextAndVersionRejectLegacyOrUnknownInterpretation() throws {
        let valid = try json(configuration())
        #expect(valid["version"] as? Int == 3 && valid["electricalContext"] as? String == "geometric")
        for version in [1, 2] {
            var legacy = valid; legacy["version"] = version
            #expect(throws: NativePEXInputError.invalidField("version")) { try decode(legacy) }
        }
        var missing = valid; missing.removeValue(forKey: "electricalContext")
        #expect(throws: DecodingError.self) { try decode(missing) }
        var unknown = valid; unknown["electricalContext"] = "unknown"
        #expect(throws: DecodingError.self) { try decode(unknown) }
    }

    @Test func exactTopAndSupplementalPinAdmissionRejectAmbiguousOrMissingSource() throws {
        let config = try configuration(), source = document()
        #expect(throws: NativePEXInputError.missingCell("ABSENT")) {
            try LayoutPEXInputPreparer().prepare(document: source, topCell: "ABSENT", configuration: config)
        }
        var duplicate = source; duplicate.cells.append(LayoutCell(name: "TOP"))
        #expect(throws: NativePEXInputError.duplicateCell("TOP")) {
            try LayoutPEXInputPreparer().prepare(document: duplicate, topCell: "TOP", configuration: config)
        }
        var pinCollision = source; pinCollision.cells[0].pins = [try #require(config.supplementalPins.first).pin]
        #expect(throws: NativePEXInputError.duplicatePin(cell: "TOP", name: "A")) {
            try LayoutPEXInputPreparer().prepare(document: pinCollision, topCell: "TOP", configuration: config)
        }
        var otherFirst = source
        let other = LayoutCell(name: "OTHER", shapes: [fixture.rect(3, 0, 2, 2)])
        otherFirst.cells.insert(other, at: 0); otherFirst.topCellID = other.id
        let prepared = try LayoutPEXInputPreparer().prepare(document: otherFirst, topCell: "TOP", configuration: config)
        #expect(prepared.snapshot.hierarchy.shapes.count == 1 && prepared.snapshot.hierarchy.rootCellID == source.cells[0].id)
    }

    @Test func halfGridPathCannotReuseRawSourceCoordinateUnits() throws {
        var source = document()
        source.cells[0].shapes = [LayoutShape(layer: fixture.m1, geometry: .path(.init(
            points: [.init(x: 0, y: 0), .init(x: 1, y: 0)], width: 0.1, endCap: .truncate)))]
        #expect(throws: NativePEXInputError.coordinateUnitsMismatch) {
            try LayoutPEXInputPreparer().prepare(document: source, topCell: "TOP", configuration: configuration(expectedCoordinateUnits: .defaultUnits))
        }
    }

    @Test func serializedBudgetsControlActualLowerExecutionAndCancellation() throws {
        let source = document(), valid = try json(configuration())
        for (owner, field) in [("captureLimits", "maximumOccurrences"), ("captureLimits", "maximumInputEntries"),
                               ("calculationLimits", "maximumMeshCells"), ("electrodeLimits", "maximumContacts"),
                               ("projectionLimits", "maximumNodes")] {
            var changed = valid, limits = try #require(valid[owner] as? [String: Any]); limits[field] = 0; changed[owner] = limits
            let config = try decode(changed)
            do { _ = try project(LayoutPEXInputPreparer().prepare(document: source, topCell: "TOP", configuration: config)); Issue.record("Lower budget ignored: \(owner).\(field)") }
            catch { #expect(error is NativePEXInputError || error is NativePEXCalculationError || error is NativePEXElectrodeError || error is NativePEXProjectionError) }
        }
        let config = try configuration()
        var exhausted = valid; exhausted["maximumMetadataEntries"] = config.metadataEntriesUsed
        let metadataBound = try decode(exhausted)
        #expect(throws: NativePEXInputError.metadataLimitExceeded) {
            try LayoutPEXInputPreparer().prepare(document: source, topCell: "TOP", configuration: metadataBound)
        }
        #expect(throws: NativePEXInputError.cancelled) {
            try LayoutPEXInputPreparer().prepare(document: source, topCell: "TOP", configuration: config, isCancelled: { true })
        }
        var calls = 0
        #expect(throws: NativePEXInputError.self) {
            try LayoutPEXInputPreparer().prepare(document: source, topCell: "TOP", configuration: config, isCancelled: { calls += 1; return calls > 12 })
        }
    }

    private func document() -> LayoutDocument {
        let cell = LayoutCell(name: "TOP", shapes: [fixture.rect(0, 0, 1, 1)],
            labels: [LayoutLabel(text: "A", position: .init(x: 0.5, y: 0.5), layer: fixture.m1)])
        return LayoutDocument(name: "native-schema", cells: [cell], topCellID: cell.id)
    }
    private func configuration(pins: [NativePEXPinDefinition]? = nil, expectedCoordinateUnits: LayoutUnits? = nil) throws -> NativePEXConfiguration {
        let net = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        return try NativePEXConfiguration(layoutTechnology: .standard(), layers: [
            .init(layerID: fixture.m1, electricalName: "M1", isConductive: true),
            .init(layerID: fixture.m2, electricalName: "M2", isConductive: true),
            .init(layerID: fixture.cut, electricalName: "C1", isConductive: false)],
            supplementalPins: pins ?? ["A", "B"].map { .init(cellName: "TOP", pin: .init(name: $0,
                position: .init(x: 0.5, y: 0.5), size: .init(width: 1, height: 1), layer: fixture.m1, netID: net)) },
            netBindings: [.init(selector: .supplemental(occurrenceIndex: 0, expectedCellName: "TOP", netID: net), netName: NetName("SIGNAL"))],
            electrodeBindings: [
                .init(pinIndex: 0, terminal: .init(netName: NetName("SIGNAL"), nodeName: NodeName("A")), faces: [.init(side: .minX, coordinate: 0, begin: 0, end: 2000)]),
                .init(pinIndex: 1, terminal: .init(netName: NetName("SIGNAL"), nodeName: NodeName("B")), faces: [.init(side: .maxX, coordinate: 2000, begin: 0, end: 2000)])],
            expectedCoordinateUnits: expectedCoordinateUnits ?? LayoutUnits(scale: try .init(databaseUnitsPerMicrometer: 2000)), maximumCellSpanDatabaseUnits: 2000,
            calculationLimits: .init(maximumMeshCells: 1), electrodeLimits: .init(maximumContacts: 2), projectionLimits: .init(maximumNodes: 3))
    }
    private func project(_ prepared: NativePEXPreparedInput) throws -> NativePEXProjection {
        let c = prepared.configuration
        let network = try RectilinearPEXCalculator().calculate(snapshot: prepared.snapshot, technology: fixture.technology(),
            corner: .init(id: "tt"), layerNames: c.layerNames, maximumCellSpanDatabaseUnits: c.maximumCellSpanDatabaseUnits, limits: c.calculationLimits)
        let electrodes = try RectilinearPEXElectrodeBuilder().build(network: network, bindings: c.electrodeBindings, limits: c.electrodeLimits)
        return try CanonicalPEXProjector().project(electrodes: electrodes, netBindings: prepared.netBindings, limits: c.projectionLimits)
    }
    private func json(_ configuration: NativePEXConfiguration) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
    }
    private func decode(_ json: [String: Any]) throws -> NativePEXConfiguration {
        try JSONDecoder().decode(NativePEXConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
