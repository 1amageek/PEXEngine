import Foundation
import CircuiteFoundation
import PEXCore
import LayoutCore
import LayoutTech
import LayoutVerify
import Testing
@testable import PEXNative

@Suite("Native PEX union mesh", .timeLimit(.minutes(1)))
struct NativePEXMeshTests {
    private let fixture = NativePEXTestFixture()

    @Test func overlappingSourcesHaveOnePhysicalCoverage() throws {
        let result = try fixture.mesh(LayoutCell(name: "OVERLAP", shapes: [fixture.rect(0, 0, 2, 1), fixture.rect(1, 0, 2, 1)]))
        #expect(result.cells.count == 3)
        #expect(abs(fixture.area(result) - 3e-12) < 1e-26)
        #expect(Set(result.cells.values.map(\.componentIndex)).count == 1)
    }

    @Test func refinementChangesCellsWithoutChangingCoverage() throws {
        let cell = LayoutCell(name: "SHEET", shapes: [fixture.rect(0, 0, 2, 1)])
        let coarse = try fixture.mesh(cell), fine = try fixture.mesh(cell, span: 250)
        #expect(coarse.cells.count == 2 && fine.cells.count == 32)
        #expect(abs(fixture.area(coarse) - fixture.area(fine)) < 1e-26)
    }

    @Test func concaveVoidRemainsUnoccupied() throws {
        let polygon = LayoutShape(layer: fixture.m1, geometry: .polygon(.init(points: [
            .init(x: 0, y: 0), .init(x: 4, y: 0), .init(x: 4, y: 1),
            .init(x: 1, y: 1), .init(x: 1, y: 4), .init(x: 0, y: 4)
        ])))
        let result = try fixture.mesh(LayoutCell(name: "L", shapes: [polygon]))
        #expect(result.cells.count == 7)
        #expect(abs(fixture.area(result) - 7e-12) < 1e-26)
        #expect(!result.orderedKeys.contains { result.x[$0.x] == 2_000 && result.y[$0.y] == 2_000 })
    }

    @Test func distantEmptySpaceDoesNotAllocateCartesianGrid() throws {
        let result = try fixture.mesh(LayoutCell(name: "SPARSE", shapes: [fixture.rect(0, 0, 1, 1), fixture.rect(1_000_000, 1_000_000, 1, 1)]))
        #expect(result.x.count == 4 && result.y.count == 4 && result.cells.count == 2)
        #expect(Set(result.cells.values.map(\.componentIndex)).count == 2)
    }

    @Test func capturedUnitScaleControlsPhysicalArea() throws {
        let cell = LayoutCell(name: "UNITS", shapes: [fixture.rect(0, 0, 2, 1)])
        let normal = try fixture.mesh(cell)
        let different = try NativePEXMesh.build(snapshot: fixture.snapshot(cell, scale: DatabaseUnitScale(databaseUnitsPerMicrometer: 500)),
            technology: fixture.technology(), corner: PEXCorner(id: "tt"), layerNames: fixture.bindings, maximumCellSpanDatabaseUnits: 500)
        #expect(normal.x == [0, 1_000, 2_000] && different.x == [0, 500, 1_000])
        #expect(abs(fixture.area(normal) - fixture.area(different)) < 1e-26)
    }

    @Test func pinLabelsKeepDisconnectedIslandsSeparate() throws {
        let pin = LayoutPin(name: "P", position: .init(x: 2, y: 0.5), size: .init(width: 4, height: 1), layer: fixture.m1, netID: UUID())
        let result = try fixture.mesh(LayoutCell(name: "PIN", shapes: [fixture.rect(0, 0, 1, 1), fixture.rect(3, 0, 1, 1)], pins: [pin]))
        #expect(result.cells.count == 2 && result.pinContacts[0].count == 2)
        #expect(Set(result.pinContacts[0].compactMap { result.cells[$0]?.componentIndex }).count == 2)
        #expect(result.snapshot.opens.count == 1)
    }

    @Test func edgeAndCornerPinAnnotationsDoNotBecomePhysicalContacts() throws {
        let edge = LayoutPin(name: "EDGE", position: .init(x: 1.5, y: 0.5), size: .init(width: 1, height: 1), layer: fixture.m1)
        let corner = LayoutPin(name: "CORNER", position: .init(x: 1.5, y: 1.5), size: .init(width: 1, height: 1), layer: fixture.m1)
        let result = try fixture.mesh(LayoutCell(name: "PINS", shapes: [fixture.rect(0, 0, 1, 1)], pins: [edge, corner]))
        #expect(result.pinContacts.map(\.count) == [0, 0])
        #expect(result.cells.count == 1)
    }

    @Test func separateLayersNeverMergeTheirCells() throws {
        let upper = LayoutShape(layer: fixture.m2, geometry: .rect(.init(origin: .zero, size: .init(width: 1, height: 1))))
        let result = try fixture.mesh(LayoutCell(name: "LAYERS", shapes: [fixture.rect(0, 0, 1, 1), upper]))
        #expect(result.cells.count == 2 && result.snapshot.components.count == 2)
        #expect(Set(result.orderedKeys.map(\.layer)).count == 2)
    }

    @Test func namedCutCellsRetainTheirActualDefinition() throws {
        let result = try fixture.mesh(LayoutCell(name: "VIA", vias: [LayoutVia(viaDefinitionID: "VIA1", position: .zero)]))
        let cuts = result.orderedKeys.filter { result.layers[$0.layer].conductor == nil }
        #expect(cuts.count == 1 && result.cells[cuts[0]]?.viaDefinitionID == "VIA1")
        #expect(result.snapshot.components.count == 1)
    }

    @Test func rolesAndCornerAreAdmittedBeforeMeshing() throws {
        let source = try fixture.snapshot(LayoutCell(name: "ROLES", shapes: [fixture.rect(0, 0, 1, 1)]))
        #expect(throws: NativePEXCalculationError.invalidLayerMapping) {
            try NativePEXMesh.build(snapshot: source, technology: fixture.technology(), corner: PEXCorner(id: "tt"),
                layerNames: [fixture.m1: "M1", fixture.m2: "M1", fixture.cut: "C1"], maximumCellSpanDatabaseUnits: 1_000)
        }
        #expect(throws: NativePEXCalculationError.electricalModel(.missing(field: "electricalModels.ss"))) {
            try NativePEXMesh.build(snapshot: source, technology: fixture.technology(), corner: PEXCorner(id: "ss"),
                layerNames: fixture.bindings, maximumCellSpanDatabaseUnits: 1_000)
        }
    }

    @Test func coordinateCellWorkAndInputLimitsRejectBeforePartialOutput() throws {
        let cell = LayoutCell(name: "LIMIT", shapes: [fixture.rect(0, 0, 1, 1)])
        #expect(throws: NativePEXCalculationError.limitExceeded(.coordinateValues)) {
            try fixture.mesh(cell, limits: .init(maximumCoordinateValues: 3))
        }
        #expect(try fixture.mesh(cell, limits: .init(maximumCoordinateValues: 4, maximumMeshCells: 1)).cells.count == 1)
        #expect(throws: NativePEXCalculationError.limitExceeded(.meshCells)) { try fixture.mesh(cell, limits: .init(maximumMeshCells: 0)) }
        #expect(throws: NativePEXCalculationError.limitExceeded(.workVisits)) { try fixture.mesh(cell, limits: .init(maximumWorkVisits: 0)) }
        #expect(throws: NativePEXCalculationError.limitExceeded(.inputRecords)) { try fixture.mesh(cell, limits: .init(maximumInputRecords: 0)) }
    }

    @Test func pinIncidenceHasItsOwnAdmissionLimit() throws {
        let pin = LayoutPin(name: "P", position: .init(x: 0.5, y: 0.5), size: .init(width: 1, height: 1), layer: fixture.m1)
        let cell = LayoutCell(name: "PIN_LIMIT", shapes: [fixture.rect(0, 0, 1, 1)], pins: [pin])
        #expect(throws: NativePEXCalculationError.limitExceeded(.pinContacts)) { try fixture.mesh(cell, limits: .init(maximumPinContacts: 0)) }
    }

    @Test func emptyGeometryAndInvalidPolicyDoNotProduceMesh() throws {
        #expect(throws: NativePEXCalculationError.emptyGeometry) { try fixture.mesh(LayoutCell(name: "EMPTY")) }
        #expect(throws: NativePEXCalculationError.invalidConfiguration) {
            try fixture.mesh(LayoutCell(name: "INVALID", shapes: [fixture.rect(0, 0, 1, 1)]), span: 0)
        }
    }

    @Test func cancellationMidFillPublishesNoMesh() throws {
        let source = try fixture.snapshot(LayoutCell(name: "CANCEL", shapes: [fixture.rect(0, 0, 2, 1)]))
        let tech = try fixture.technology()
        var checks = 0
        var output: NativePEXMesh?
        #expect(throws: NativePEXCalculationError.cancelled) {
            output = try NativePEXMesh.build(snapshot: source, technology: tech, corner: PEXCorner(id: "tt"),
                layerNames: fixture.bindings, maximumCellSpanDatabaseUnits: 10, isCancelled: {
                    checks += 1
                    return checks == 1_000
                })
        }
        #expect(output == nil && checks == 1_000)
    }

    @Test func actualTaskCancellationUsesDefaultGuard() async throws {
        let source = try fixture.snapshot(LayoutCell(name: "TASK", shapes: [fixture.rect(0, 0, 1, 1)]))
        let tech = try fixture.technology(), names = fixture.bindings
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try NativePEXMesh.build(snapshot: source, technology: tech, corner: PEXCorner(id: "tt"),
                layerNames: names, maximumCellSpanDatabaseUnits: 1_000)
        }
        await #expect(throws: NativePEXCalculationError.cancelled) { try await task.value }
    }
}
