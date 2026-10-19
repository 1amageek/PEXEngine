import Foundation
import Testing
import CircuiteFoundation
import PEXCore
import PEXNative
@testable import PEXAdapters

@Suite("Exact standard routed input preparation", .timeLimit(.minutes(1)))
struct NativeRoutedPEXInputPreparationTests {
    @Test func actualOwnedCodecsPreserveUnitsExtensionsPitchAndTerminalIdentity() throws {
        let f = try RoutedPreparationFixture(extraCorner: true)
        defer { cleanup(f) }
        let prepared = try DefaultNativeRoutedPEXInputPreparer().prepare(context: f.context(), requiredCornerIDs: ["nominal", "fast"])
        #expect(prepared.input.defArtifactID == f.def.id)
        #expect(prepared.input.databaseUnitsPerMicron == 1000)
        #expect(prepared.input.layers.count == 6)
        let li = try #require(prepared.input.layers.first { $0.name == "li1" })
        #expect(li.pitchDatabaseUnits == 460 && li.defaultWidthDatabaseUnits == 200)
        #expect(li.firstDEFTrackX == 230 && li.searchOriginX == 130 && li.searchOriginY == 0)
        let wire = try #require(prepared.input.wires.first)
        #expect(wire.rect == .init(minX: 400, minY: 2300, maxX: 2400, maxY: 2500))
        let pin = try #require(prepared.input.terminals.first { $0.ref.nodeName == NodeName("U2:A") })
        #expect(pin.instancePath == InstancePath("U2"))
        #expect(pin.contacts[0].rect == .init(minX: 2200, minY: 2300, maxX: 2400, maxY: 2500))
        let node = try #require(prepared.input.nodes.first { $0.ref == pin.ref })
        #expect(node.x == 2300 && node.y == 2400)
        #expect(prepared.model.selection.rulesArtifactID == f.rules.id)
        #expect(prepared.maximumCellSpanDatabaseUnits == f.configuration.maximumCellSpanDatabaseUnits)
        #expect(prepared.groundCapacitanceModel.selection == f.corner.selection)
        #expect(prepared.groundCapacitanceModel.cornerID == "nominal")
        #expect(prepared.groundCapacitanceModel.layers.allSatisfy { $0.areaPicofaradsPerSquareMicron == 0.0001 })

        #expect(Set(prepared.sourceReferences) == Set([f.def, f.netlist, f.routeTech, f.fullTech, f.cell, f.rules]))
    }

    @Test func actualViaOnlyPinRetainsNamedAliasAndPerCutSourceResistance() throws {
        let f = try RoutedPreparationFixture(viaOnly: true)
        defer { cleanup(f) }
        let prepared = try DefaultNativeRoutedPEXInputPreparer().prepare(context: f.context(), requiredCornerIDs: ["nominal"])
        #expect(prepared.input.wires.count == 1 && prepared.input.vias.count == 2)
        #expect(prepared.input.vias.allSatisfy { $0.cuts.count == 1 && $0.cuts[0].resistanceOhms == 9.3 })
        #expect(prepared.input.terminals.count == 2)
        let pin = try #require(prepared.input.terminals.first { $0.ref.nodeName == NodeName("U2:A") })
        #expect(pin.instancePath == InstancePath("U2"))
        let actual = try #require(prepared.input.nodes.first { $0.ref == pin.ref })
        #expect(actual.layerName == "li1" && actual.x == 2300 && actual.y == 2400)
        #expect(prepared.input.vias.allSatisfy { $0.landings.count == 2 })
    }

    @Test func actualSourcePoseUsesOrientationAndSizeWithoutPinCenterGuessing() throws {
        let f = try RoutedPreparationFixture(orientation: "FE", endpointX: 2600, endpointY: 3700)
        defer { cleanup(f) }
        let prepared = try DefaultNativeRoutedPEXInputPreparer().prepare(context: f.context(), requiredCornerIDs: ["nominal"])
        let pin = try #require(prepared.input.terminals.first { $0.ref.nodeName == NodeName("U2:A") })
        #expect(pin.contacts[0].rect == .init(minX: 2500, minY: 3600, maxX: 2700, maxY: 3800))
        let node = try #require(prepared.input.nodes.first { $0.ref == pin.ref })
        #expect(node.x == 2600 && node.y == 3700)
    }

    @Test func explicitCornerResistanceIsNotForcedToNominalRouteView() throws {
        let f = try RoutedPreparationFixture(fullTechOverride: RoutedPreparationFixture.technology(full: true, resistance: "25.6"))
        defer { cleanup(f) }
        let prepared = try DefaultNativeRoutedPEXInputPreparer().prepare(context: f.context(), requiredCornerIDs: ["nominal"])
        #expect(prepared.input.layers[0].sheetResistanceOhmsPerSquare == 25.6)
    }

    @Test func exactSourceMutationAndUsedGeometryMismatchFail() throws {
        let modified = try RoutedPreparationFixture()
        defer { cleanup(modified) }
        try Data("modified".utf8).write(to: modified.routeTechURL)
        #expect(throws: NativeRoutedPEXPreparationError.self) {
            try DefaultNativeRoutedPEXInputPreparer().prepare(context: modified.context(), requiredCornerIDs: ["nominal"])
        }
        let mismatch = try RoutedPreparationFixture(fullTechOverride: RoutedPreparationFixture.technology(full: true, width: "0.3"))
        defer { cleanup(mismatch) }
        #expect(throws: NativeRoutedPEXPreparationError.self) {
            try DefaultNativeRoutedPEXInputPreparer().prepare(context: mismatch.context(), requiredCornerIDs: ["nominal"])
        }
    }

    @Test func sourceUnitsAndCriticalUnretainedConnectivityCannotBeInvented() throws {
        let original = try RoutedPreparationFixture()
        defer { cleanup(original) }
        let source = try String(contentsOf: original.defURL, encoding: .utf8)
        for invalid in [source.replacingOccurrences(of: "UNITS DISTANCE MICRONS 1000 ;", with: ""),
                        source.replacingOccurrences(of: "- signal ( PIN input )", with: "- signal + VPIN hidden ( 1 1 ) ( PIN input )")] {
            let f = try RoutedPreparationFixture(defOverride: invalid)
            defer { cleanup(f) }
            #expect(throws: NativeRoutedPEXPreparationError.self) {
                try DefaultNativeRoutedPEXInputPreparer().prepare(context: f.context(), requiredCornerIDs: ["nominal"])
            }
        }
    }

    @Test func cancellationAndFiniteHostQuotaFailBeforeSuccessfulPreparation() async throws {
        let f = try RoutedPreparationFixture()
        defer { cleanup(f) }
        for diagnostic in ["Routed configuration", "Source read"] {
            let observed = await Task.detached { () -> NativeRoutedPEXPreparationError? in
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    _ = try DefaultNativeRoutedPEXInputPreparer.readInput(f.defURL,
                        maximumBytes: 16000000, diagnostic: diagnostic)
                    return nil
                } catch let error as NativeRoutedPEXPreparationError { return error }
                catch {
                    Issue.record("Unexpected preparation error: \(error)")
                    return nil
                }
            }.value
            #expect(observed == .cancelled)
        }
        let bytes = try DefaultNativeRoutedPEXInputPreparer.readInput(f.defURL,
            maximumBytes: 16000000, diagnostic: "Source read")
        #expect(!bytes.isEmpty)
        do {
            _ = try DefaultNativeRoutedPEXInputPreparer.readInput(f.defURL,
                maximumBytes: 1, diagnostic: "Source read")
            Issue.record("An over-ceiling source read succeeded")
        } catch {
            guard case .sourceDecode = error else {
                Issue.record("An ordinary reader failure changed classification: \(error)")
                return
            }
        }
        #expect(throws: NativeRoutedPEXPreparationError.cancelled) {
            try DefaultNativeRoutedPEXInputPreparer().prepare(context: f.context(), requiredCornerIDs: ["nominal"], isCancelled: { true })
        }
        let bounded = try RoutedPreparationFixture(limits: .init(maximumSourceBytes: 16000000, maximumTotalSourceBytes: 64000000,
            maximumRecords: 100000, maximumStringBytes: 1000000, maximumWorkVisits: 1, maximumNetlistManagedStorageBytes: 64000000, maximumNetlistAllocationBytes: 128000000))
        defer { cleanup(bounded) }
        #expect(throws: NativeRoutedPEXPreparationError.limitExceeded("workVisits")) {
            try DefaultNativeRoutedPEXInputPreparer().prepare(context: bounded.context(), requiredCornerIDs: ["nominal"])
        }
        let originalSource = try String(contentsOf: f.defURL, encoding: .utf8)
        let largeName = String(repeating: "u", count: 2048)
        let named = try RoutedPreparationFixture(defOverride: originalSource.replacingOccurrences(of: "U2", with: largeName),
            limits: .init(maximumSourceBytes: 16000000, maximumTotalSourceBytes: 64000000,
                maximumRecords: 100000, maximumStringBytes: 3000, maximumWorkVisits: 100000000, maximumNetlistManagedStorageBytes: 64000000, maximumNetlistAllocationBytes: 128000000))
        defer { cleanup(named) }
        #expect(throws: NativeRoutedPEXPreparationError.limitExceeded("stringBytes")) {
            try DefaultNativeRoutedPEXInputPreparer().prepare(context: named.context(), requiredCornerIDs: ["nominal"])
        }
    }

    @Test func largeOrOffGridSourceDimensionsAreTypedRefusals() throws {
        for width in ["9007199254740992", "0.2005"] {
            let f = try RoutedPreparationFixture(fullTechOverride: RoutedPreparationFixture.technology(full: true, width: width))
            defer { cleanup(f) }
            #expect(throws: NativeRoutedPEXPreparationError.self) {
                try DefaultNativeRoutedPEXInputPreparer().prepare(context: f.context(), requiredCornerIDs: ["nominal"])
            }
        }
    }

    private func cleanup(_ fixture: RoutedPreparationFixture) {
        do { try fixture.remove() }
        catch { Issue.record("Routed source fixture cleanup failed: \(error)") }
    }
}
