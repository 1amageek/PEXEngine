import Foundation
import PEXCore
import PEXParsers
import Testing
@testable import PEXNative

@Suite("Complete bounded routed RC graph", .timeLimit(.minutes(1)))
struct RoutedPEXCalculationTests {
    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(1e-28, abs(b) * 1e-11) }

    @Test func isolatedWirePreservesBBoxResistanceAndTwoOpenSideCapacitances() throws {
        let f = try RoutedPEXFixture()
        let input = f.input([.init(id: "S", net: "S", x0: 100, y0: 100, x1: 1100, y1: 100)])
        let value = try f.calculate(input)
        let net = try #require(value.ir.nets.first)
        #expect(close(net.totalResistanceOhm, 202))
        #expect(close(net.totalGroundCapF, 2 * 1010e-18))
        #expect(net.totalCouplingCapF == 0)
        #expect(net.nodes.filter { $0.kind == .pin }.count == 2)
        #expect(value.queryReceipts.count == 2)
        #expect(value.ir.metadata["native.routed.pinCapacitance"] == "excluded")
    }

    @Test func nearestPartialWireConsumesOnlyItsVisibleInterval() throws {
        let f = try RoutedPEXFixture()
        let value = try f.calculate(f.input([
            .init(id: "S", net: "S", x0: 100, y0: 100, x1: 1100, y1: 100),
            .init(id: "N", net: "N", x0: 100, y0: 130, x1: 700, y1: 130),
            .init(id: "F", net: "F", x0: 100, y0: 160, x1: 1100, y1: 160)]))
        let near = value.queryReceipts.filter { $0.sourceIDs == ["S", "N"] && $0.context.kind == .over }
        let far = value.queryReceipts.filter { $0.sourceIDs == ["S", "F"] && $0.context.kind == .over }
        #expect(near.map(\.effectiveLengthDatabaseUnits) == [1220])
        #expect(far.map(\.effectiveLengthDatabaseUnits) == [800])
        let source = try #require(value.ir.nets.first { $0.name == NetName("S") })
        #expect(close(source.totalCouplingCapF, 2 * 1010 * 2e-18))
        let elementTotal = value.ir.elements.filter { $0.kind == .coupling }.reduce(0) { $0 + $1.value }
        #expect(close(value.ir.nets.reduce(0) { $0 + $1.totalCouplingCapF }, 2 * elementTotal))
    }

    @Test func thresholdEqualityProducesNoLateralPairAndInputOrderDoesNotChangeIR() throws {
        let f = try RoutedPEXFixture()
        let input = f.input([.init(id: "S", net: "S", x0: 100, y0: 100, x1: 1100, y1: 100),
                             .init(id: "T", net: "T", x0: 100, y0: 1110, x1: 1100, y1: 1110)])
        let a = try f.calculate(input), b = try f.calculate(f.replace(input, wires: input.wires.reversed(), nodes: input.nodes.reversed()))
        #expect(a.ir == b.ir)
        #expect(a.ir.elements.allSatisfy { $0.kind != .coupling })
    }

    @Test func TjunctionAddsOneSharedNodeAndPreservesAllBranchResistance() throws {
        let f = try RoutedPEXFixture()
        let value = try f.calculate(f.input([.init(id: "H", net: "S", x0: 100, y0: 100, x1: 1100, y1: 100),
                                            .init(id: "V", net: "S", x0: 600, y0: 100, x1: 600, y1: 600)]))
        let net = try #require(value.ir.nets.first)
        #expect(close(net.totalResistanceOhm, 202 + 102))
        let junction = try #require(net.nodes.first { $0.name == NodeName("V.a") })
        #expect(junction.coordinate?.x == 0.6 && junction.coordinate?.y == 0.1)
        let incidence = value.ir.elements.filter { $0.kind == .resistor && ($0.nodeA.nodeName == junction.name || $0.nodeB?.nodeName == junction.name) }
        #expect(incidence.count == 3)
    }

    @Test func diagonalSignalAndExplicitPGTargetsPreservePositiveQuantities() throws {
        let f = try RoutedPEXFixture()
        for role in [NativeRoutedPEXInput.Role.signal, .reference] {
            let input = f.input([.init(id: "S", net: "S", x0: 100, y0: 100, x1: 1100, y1: 100),
                .init(id: "T", net: "T", role: role, layer: 3, x0: 100, y0: 230, x1: 1100, y1: 230)])
            let value = try f.calculate(input)
            let diagonal = value.queryReceipts.filter { $0.context.kind == .diagUnder }
            #expect(diagonal.count == 2)
            #expect(diagonal.allSatisfy { $0.fringeFarads > 0 })
            let source = try #require(value.ir.nets.first { $0.name == NetName("S") })
            if role == .reference {
                #expect(value.ir.nets.count == 1 && source.totalCouplingCapF == 0)
                #expect(close(source.totalGroundCapF, 4 * 1010e-18))
            } else { #expect(close(source.totalCouplingCapF, 2 * 1010e-18)) }
        }
    }

    @Test func viaCutResistanceAndHighestLandingOverwriteRemainSeparateFromSearch() throws {
        let f = try RoutedPEXFixture()
        let original = f.input([.init(id: "L", net: "S", x0: 100, y0: 100, x1: 600, y1: 100),
                               .init(id: "U", net: "S", layer: 3, x0: 600, y0: 100, x1: 1100, y1: 100)])
        let via = NativeRoutedPEXInput.Via(sourceID: "V", sourceOrdinal: 2, netName: NetName("S"),
            sourceNode: original.wires[0].targetNode, targetNode: original.wires[1].sourceNode,
            cuts: [598, 602].map { .init(layerName: "via", rect: .init(minX: Int64($0), minY: 99, maxX: Int64($0 + 2), maxY: 101), resistanceOhms: 8, sourceFacts: f.facts) },
            landings: [.init(layerName: "met1", rect: .init(minX: 595, minY: 95, maxX: 605, maxY: 105), sourceFacts: f.facts),
                       .init(layerName: "met2", rect: .init(minX: 590, minY: 95, maxX: 610, maxY: 105), sourceFacts: f.facts)], sourceFacts: f.facts)
        let value = try f.calculate(f.replace(original, vias: [via], terminals: original.terminals.filter {
            $0.ref == original.wires[0].sourceNode || $0.ref == original.wires[1].targetNode
        }))
        #expect(close(try #require(value.ir.nets.first).totalResistanceOhm, 208))
        let landing = try #require(value.viaLandingReceipts.first)
        #expect(landing.selectedLayerName == "met2")
        #expect(close(landing.groundCapacitanceFarads, 40e-18))
        #expect(value.queryReceipts.filter { $0.sourceIDs == ["V"] }.count == 1)
    }

    @Test func GSInclusivePixelBoundariesSelectExactOverUnderAndOverUnderLengths() throws {
        let f = try RoutedPEXFixture()
        let source = RoutedPEXFixture.WireSpec(id: "S", net: "S", x0: 100, y0: 100, x1: 1100, y1: 100)
        let lower = RoutedPEXFixture.WireSpec(id: "L", net: "L", layer: 1, x0: 600, y0: 50, x1: 600, y1: 150)
        let upper = RoutedPEXFixture.WireSpec(id: "U", net: "U", layer: 3, x0: 600, y0: 50, x1: 600, y1: 150)
        let cases: [([RoutedPEXFixture.WireSpec], PEXOpenRCXSourceModel.Context)] = [
            ([source, lower], .init(metal: 2, kind: .over, underMetal: 1)),
            ([source, upper], .init(metal: 2, kind: .under, overMetal: 3)),
            ([source, lower, upper], .init(metal: 2, kind: .overUnder, underMetal: 1, overMetal: 3))]
        for (specs, context) in cases {
            let value = try f.calculate(f.input(specs))
            let sourceQueries = value.queryReceipts.filter { $0.sourceIDs == ["S"] }
            // The actual [595,605] bbox paints pixels 59 and 60. Their inclusive
            // run is [590,609], whose consumer black length is 609 - 590 = 19.
            #expect(sourceQueries.filter { $0.context == context }.map(\.effectiveLengthDatabaseUnits) == [19, 19])
            #expect(sourceQueries.filter { $0.context.kind == .over && $0.context.underMetal == 0 }
                .map(\.effectiveLengthDatabaseUnits) == [991, 991])
            let net = try #require(value.ir.nets.first { $0.name == NetName("S") })
            #expect(close(net.totalGroundCapF, 2 * 1010e-18))
            #expect(net.totalCouplingCapF == 0)
        }
        let context = PEXOpenRCXSourceModel.Context(metal: 2, kind: .overUnder, underMetal: 1, overMetal: 3)
        let missing = try RoutedPEXFixture(empty: context)
        #expect(throws: NativeRoutedPEXError.rule(context: context, cause: .emptyActiveTable, sourceIDs: ["S"])) {
            try missing.calculate(missing.input([source, lower, upper]))
        }
    }

    @Test func diagonalNearestIntervalsAndDirectionalCursorRestartPreserveBothSides() throws {
        let f = try RoutedPEXFixture()
        let partial = try f.calculate(f.input([
            .init(id: "S", net: "S", x0: 100, y0: 120, x1: 1100, y1: 120),
            .init(id: "N", net: "N", layer: 3, x0: 100, y0: 150, x1: 700, y1: 150),
            .init(id: "F", net: "F", layer: 3, x0: 100, y0: 250, x1: 1100, y1: 250)]))
        let diagonal = partial.queryReceipts.filter { $0.context.kind == .diagUnder }
        #expect(diagonal.filter { $0.sourceIDs == ["S", "N"] }.map(\.effectiveLengthDatabaseUnits) == [610, 610])
        #expect(diagonal.filter { $0.sourceIDs == ["S", "F"] }.map(\.effectiveLengthDatabaseUnits) == [400, 400])
        let source = try #require(partial.ir.nets.first { $0.name == NetName("S") })
        #expect(close(source.totalCouplingCapF, 2 * 1010e-18))

        let separated = try f.calculate(f.input([
            .init(id: "S", net: "S", x0: 100, y0: 120, x1: 500, y1: 120),
            .init(id: "Q", net: "Q", x0: 700, y0: 120, x1: 1100, y1: 120),
            .init(id: "A", net: "A", layer: 3, x0: 100, y0: 150, x1: 500, y1: 150),
            .init(id: "B", net: "B", layer: 3, x0: 700, y0: 150, x1: 1100, y1: 150)]))
        let queries = separated.queryReceipts.filter { $0.context.kind == .diagUnder }
        // Track::couplingCaps initializes the target cursor at each directional
        // pass, then advances it across the source callbacks inside that pass.
        #expect(queries.filter { $0.sourceIDs == ["S", "A"] }.map(\.effectiveLengthDatabaseUnits) == [410, 410])
        #expect(queries.filter { $0.sourceIDs == ["Q", "B"] }.map(\.effectiveLengthDatabaseUnits) == [410, 410])
        for name in ["S", "Q"] {
            let net = try #require(separated.ir.nets.first { $0.name == NetName(name) })
            #expect(close(net.totalCouplingCapF, 2 * 410e-18))
        }
    }

    @Test func provenCoincidentTerminalsPreservePinIdentitiesThroughZeroOhmSPEFConnections() throws {
        let f = try RoutedPEXFixture()
        let original = f.input([.init(id: "S", net: "S", x0: 100, y0: 120, x1: 1100, y1: 120)])
        let first = original.nodes[0]
        let ref = NodeRef(netName: first.ref.netName, nodeName: NodeName("U2:A"))
        let alias = NativeRoutedPEXInput.Node(ref: ref, layerName: first.layerName, x: first.x, y: first.y, sourceFacts: f.facts)
        let contact = NativeRoutedPEXInput.Landing(layerName: first.layerName,
            rect: .init(minX: 95, minY: 115, maxX: 105, maxY: 125), sourceFacts: f.facts)
        let terminal = NativeRoutedPEXInput.Terminal(ref: ref, instancePath: InstancePath("U2"), contacts: [contact], sourceFacts: f.facts)
        let input = f.replace(original, terminals: original.terminals + [terminal], nodes: original.nodes + [alias])
        let value = try f.calculate(input)
        let net = try #require(value.ir.nets.first)
        #expect(Set(net.nodes.filter { $0.kind == .pin }.map(\.name)) == Set([first.ref.nodeName, original.nodes[1].ref.nodeName, ref.nodeName]))
        let zero = value.ir.elements.filter { $0.kind == .resistor && $0.value == 0 }
        #expect(zero.count == 2)
        #expect(Set(zero.map(\.nodeA)) == Set([first.ref, ref]))
        #expect(Set(zero.compactMap(\.nodeB)).count == 1)
        let junction = try #require(zero.first?.nodeB)
        #expect(net.nodes.first { $0.name == junction.nodeName }?.kind == .internal)
        #expect(close(net.totalResistanceOhm, 202) && close(net.totalGroundCapF, 2020e-18))
        #expect(try f.calculate(f.replace(input, nodes: input.nodes.reversed())).ir == value.ir)

        let spef = try SPEFWriter().write(value.ir)
        var lexer = SPEFLexer(source: spef)
        let replay = try SPEFLowering().lower(SPEFParser().parse(tokens: lexer.tokenize()), cornerID: "tt")
        let replayNet = try #require(replay.nets.first)
        #expect(Set(replayNet.nodes.filter { $0.kind == .pin }) == Set(net.nodes.filter { $0.kind == .pin }))
        #expect(replay.elements.filter { $0.kind == .resistor && $0.value == 0 }.count == 2)
        #expect(close(replayNet.totalResistanceOhm, net.totalResistanceOhm))

        let absent = NativeRoutedPEXInput.Terminal(ref: ref, contacts: [.init(layerName: first.layerName,
            rect: .init(minX: 300, minY: 300, maxX: 310, maxY: 310), sourceFacts: f.facts)], sourceFacts: f.facts)
        #expect(throws: NativeRoutedPEXError.invalidInput(reason: .terminal, sourceIDs: ["U2:A"])) {
            try f.calculate(f.replace(original, terminals: original.terminals + [absent], nodes: original.nodes + [alias]))
        }
        let crossNet = f.input([.init(id: "S", net: "S", x0: 100, y0: 120, x1: 1100, y1: 120),
                               .init(id: "X", net: "X", x0: 100, y0: 120, x1: 100, y1: 600)])
        #expect(throws: NativeRoutedPEXError.invalidInput(reason: .shortCircuit, sourceIDs: ["S", "X"])) { try f.calculate(crossNet) }
    }

    @Test func wideWireCloneUsesItsActualTrackHeadWithoutChangingOriginalSubtrackBase() throws {
        let f = try RoutedPEXFixture()
        let original = f.input([
            .init(id: "S", net: "S", x0: 100, y0: 350, x1: 1100, y1: 350),
            .init(id: "T", net: "T", layer: 3, x0: 100, y0: 705, x1: 1100, y1: 705)])
        let source = original.wires[0]
        let wide = NativeRoutedPEXInput.Wire(sourceID: source.sourceID, sourceOrdinal: source.sourceOrdinal,
            netName: source.netName, layerName: source.layerName, axis: source.axis,
            rect: .init(minX: source.rect.minX, minY: 0, maxX: source.rect.maxX, maxY: 700),
            sourceNode: source.sourceNode, targetNode: source.targetNode, sourceFacts: source.sourceFacts)
        let input = f.replace(original, wires: [wide, original.wires[1]])
        let value = try f.calculate(input)
        // The high-edge clone is on pitch track 7 with placed base 700. Its
        // diagonal target is at offset 0; the original low edge sees offset 7.
        #expect(value.queryReceipts.filter { $0.context.kind == .diagUnder && $0.sourceIDs == ["S", "T"] }
            .map(\.effectiveLengthDatabaseUnits) == [1010])
        let net = try #require(value.ir.nets.first { $0.name == NetName("S") })
        #expect(close(net.totalCouplingCapF, 1010e-18))
        #expect(try f.calculate(f.replace(input, wires: input.wires.reversed())).ir == value.ir)

        let offset = f.input([
            .init(id: "S", net: "S", x0: 100, y0: 160, x1: 1100, y1: 160),
            .init(id: "T", net: "T", layer: 3, x0: 100, y0: 305, x1: 1100, y1: 305)])
        let layers = offset.layers.map { layer in
            NativeRoutedPEXInput.Layer(name: layer.name, level: layer.level,
                preferredDirection: layer.preferredDirection, pitchDatabaseUnits: layer.level == 3 ? 60 : layer.pitchDatabaseUnits,
                defaultWidthDatabaseUnits: layer.defaultWidthDatabaseUnits, sheetResistanceOhmsPerSquare: layer.sheetResistanceOhmsPerSquare,
                searchOriginX: layer.searchOriginX, searchOriginY: layer.searchOriginY,
                originDerivationX: layer.originDerivationX, originDerivationY: layer.originDerivationY,
                firstDEFTrackX: layer.firstDEFTrackX, firstDEFTrackY: layer.firstDEFTrackY, sourceFacts: layer.sourceFacts)
        }
        let physical = try f.calculate(f.replace(offset, layers: layers))
        // Original base 155 maps to upper track 2 and reaches target track 5.
        // Replacing every context base with pitch base 100 would miss that target.
        #expect(physical.queryReceipts.filter { $0.context.kind == .diagUnder && $0.sourceIDs == ["S", "T"] }
            .map(\.effectiveLengthDatabaseUnits) == [1010, 1010])
    }

    @Test func sourceArtifactCollectionIsAdmittedBeforeSetMaterialization() throws {
        let f = try RoutedPEXFixture()
        let original = f.input([.init(id: "S", net: "S", x0: 100, y0: 120, x1: 1100, y1: 120)])
        let oversized = f.replace(original, sourceArtifacts: original.sourceArtifacts + Array(repeating: original.sourceArtifacts[0], count: 100))
        func limits(records: Int, work: Int) -> NativeRoutedPEXLimits {
            .init(maximumInputRecords: records, maximumStringBytes: 100_000, maximumSourceRecords: 10_000,
                maximumWorkVisits: work, maximumTrackEntries: 100_000, maximumCoordinateValues: 100_000,
                maximumGraphNodes: 10_000, maximumGraphElements: 100_000, maximumQueryReceipts: 100_000)
        }
        #expect(throws: NativeRoutedPEXError.limitExceeded(.inputRecords)) { try f.calculate(oversized, limits: limits(records: 16, work: 1_000_000)) }
        #expect(throws: NativeRoutedPEXError.limitExceeded(.workVisits)) {
            var budget = try NativeRoutedPEXWorkBudget(limits(records: 100_000, work: 16))
            _ = try NativeRoutedPEXGeometry(input: oversized, model: f.model, budget: &budget, isCancelled: { false })
        }
        #expect(throws: NativeRoutedPEXError.cancelled) {
            var budget = try NativeRoutedPEXWorkBudget(f.limits)
            _ = try NativeRoutedPEXGeometry(input: oversized, model: f.model, budget: &budget, isCancelled: { true })
        }
    }

    @Test func actualShortDuplicateMissingRuleCancellationAndCumulativeLimitRefuse() throws {
        let f = try RoutedPEXFixture()
        let s = RoutedPEXFixture.WireSpec(id: "S", net: "S", x0: 100, y0: 100, x1: 1100, y1: 100)
        let short = f.input([s, .init(id: "X", net: "X", x0: 600, y0: 50, x1: 600, y1: 150)])
        #expect(throws: NativeRoutedPEXError.invalidInput(reason: .shortCircuit, sourceIDs: ["S", "X"])) { try f.calculate(short) }
        let duplicate = f.input([s, .init(id: "X", net: "S", x0: 200, y0: 100, x1: 1000, y1: 100)])
        #expect(throws: NativeRoutedPEXError.invalidInput(reason: .duplicateWire, sourceIDs: ["S", "X"])) { try f.calculate(duplicate) }
        #expect(throws: NativeRoutedPEXError.cancelled) { try f.calculate(f.input([s]), isCancelled: { true }) }
        let empty = try RoutedPEXFixture(empty: .init(metal: 2, kind: .over, underMetal: 0))
        #expect(throws: NativeRoutedPEXError.rule(context: .init(metal: 2, kind: .over, underMetal: 0), cause: .emptyActiveTable, sourceIDs: ["S"])) {
            try empty.calculate(empty.input([s]))
        }
        let input = f.input([s]), complete = try f.calculate(input)
        let low = NativeRoutedPEXLimits(maximumInputRecords: 100_000, maximumStringBytes: 100_000,
            maximumSourceRecords: 10_000, maximumWorkVisits: complete.workVisitsConsumed - 1, maximumTrackEntries: 100_000,
            maximumCoordinateValues: 100_000, maximumGraphNodes: 10_000, maximumGraphElements: 100_000, maximumQueryReceipts: 100_000)
        #expect(throws: NativeRoutedPEXError.limitExceeded(.workVisits)) { try f.calculate(input, limits: low) }
    }
}
