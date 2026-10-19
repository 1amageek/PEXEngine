import PEXCore
import Synchronization
import Testing
@testable import PEXNative

@Suite("Union sheet routed RC composition", .timeLimit(.minutes(1)))
struct NativeUnionSheetRoutedPEXTests {
    private typealias Input = NativeRoutedPEXInput

    @Test func finiteFullWidthPortsMatchAnalyticResistanceAndAreaBoundaryGround() throws {
        let fixture = try RoutedPEXFixture()
        let input = rectangle(fixture)
        for span: Int32 in [100, 25, 10] {
            let result = try calculate(input, fixture, span: span)
            // Finite Dirichlet PORT regions leave length 100 and width 20 at Rs = 2.
            #expect(close(try resistance(result.ir, from: input.terminals[0].ref, to: input.terminals[1].ref), 10))
            let net = try #require(result.ir.nets.first)
            // Physical metal: area .0024 um2; complete perimeter .28 um.
            #expect(close(net.totalGroundCapF, (2 * 0.0024 + 3 * 0.28) * 1e-12))
            #expect(net.totalCouplingCapF == 0)
            #expect(result.ir.elements.allSatisfy { $0.kind != .coupling })
            #expect(result.ir.metadata["native.routed.discretization"] == "native-union-sheet-area-boundary-v1")
            #expect(Set(net.nodes.filter { $0.kind == .pin }.map(\.name))
                == Set(input.terminals.map { $0.ref.nodeName }))
            assertCapacitanceTotals(result.ir)
        }
    }

    @Test func duplicateSubdivisionAndOrderPreserveRectanglePhysicalRC() throws {
        let fixture = try RoutedPEXFixture(), original = rectangle(fixture)
        let whole = original.wires[0]
        let midpoint = NodeRef(netName: whole.netName, nodeName: NodeName("midpoint"))
        let middle = Input.Node(ref: midpoint, layerName: whole.layerName, x: 160, y: 100, sourceFacts: fixture.facts)
        let left = wire(whole, id: "left", ordinal: 0, rect: rect(100, 90, 160, 110), target: midpoint)
        let right = wire(whole, id: "right", ordinal: 1, rect: rect(160, 90, 220, 110), source: midpoint)
        let duplicate = wire(whole, id: "duplicate", ordinal: 2, rect: whole.rect)
        let variants = [original,
            fixture.replace(original, wires: [whole, duplicate]),
            fixture.replace(original, wires: [left, right], nodes: original.nodes + [middle]),
            fixture.replace(original, wires: [right, left], nodes: (original.nodes + [middle]).reversed())]
        for input in variants {
            let result = try calculate(input, fixture, span: 25)
            #expect(close(try resistance(result.ir, from: original.terminals[0].ref, to: original.terminals[1].ref), 10))
            #expect(close(try #require(result.ir.nets.first).totalGroundCapF, 0.8448e-12))
            #expect(Set(result.sourceFacts).isSuperset(of: Set(fixture.facts)))
            assertCapacitanceTotals(result.ir)
        }
    }

    @Test func actualLAndViaContactIncludeTheThirtyFiveDatabaseUnitExtension() throws {
        let fixture = try RoutedPEXFixture()
        let noVia = actualShortTurn(fixture, cutOhms: nil)
        let plain = try calculate(noVia, fixture, span: 85)
        let plainNet = try #require(plain.ir.nets.first)
        #expect(close(plainNet.totalGroundCapF, (2 * 0.11305 + 3 * 1.67) * 1e-12))
        #expect(try resistance(plain.ir, from: noVia.terminals[0].ref, to: noVia.terminals[1].ref) > 0)
        let four = actualShortTurn(fixture, cutOhms: 4)
        let eight = actualShortTurn(fixture, cutOhms: 8)
        let result4 = try calculate(four, fixture, span: 85)
        let result8 = try calculate(eight, fixture, span: 85)
        let r4 = try resistance(result4.ir, from: four.terminals[0].ref, to: four.terminals[1].ref)
        let r8 = try resistance(result8.ir, from: eight.terminals[0].ref, to: eight.terminals[1].ref)
        #expect(r4.isFinite && r4 > 0 && r8 > r4)
        // Upper landing is exactly 170 x 35: its metal adds area .00595 and perimeter .41.
        let expectedGround = (2 * (0.11305 + 0.00595) + 3 * (1.67 + 0.41)) * 1e-12
        #expect(close(try #require(result4.ir.nets.first).totalGroundCapF, expectedGround))
        #expect(close(try #require(result8.ir.nets.first).totalGroundCapF, expectedGround))
        assertCapacitanceTotals(result4.ir)
    }

    @Test func refinementPreservesGroundAndReciprocalCouplingWhileChangingTheResistorGraph() throws {
        let fixture = try RoutedPEXFixture(), input = pair(fixture)
        let coarse = try calculate(input, fixture, span: 100)
        let fine = try calculate(input, fixture, span: 10)
        #expect(fine.ir.elements.filter { $0.kind == .resistor }.count
            > coarse.ir.elements.filter { $0.kind == .resistor }.count)
        for name in ["S", "T"] {
            let a = try #require(coarse.ir.nets.first { $0.name == NetName(name) })
            let b = try #require(fine.ir.nets.first { $0.name == NetName(name) })
            #expect(close(a.totalGroundCapF, 0.8448e-12))
            #expect(close(b.totalGroundCapF, a.totalGroundCapF))
            #expect(a.totalCouplingCapF > 0 && close(b.totalCouplingCapF, a.totalCouplingCapF))
            let ports = input.terminals.filter { $0.ref.netName == NetName(name) }
            #expect(close(try resistance(fine.ir, from: ports[0].ref, to: ports[1].ref), 10))
        }
        assertCapacitanceTotals(coarse.ir)
        assertCapacitanceTotals(fine.ir)
    }

    @Test func signalCouplingIsReciprocalAndReferenceConversionAddsOnlyRawCouplingToGround() throws {
        let fixture = try RoutedPEXFixture()
        for diagonal in [false, true] {
            let signals = try calculate(pair(fixture, diagonal: diagonal), fixture)
            let reference = try calculate(pair(fixture, reference: true, diagonal: diagonal), fixture)
            let s = try #require(signals.ir.nets.first { $0.name == NetName("S") })
            let t = try #require(signals.ir.nets.first { $0.name == NetName("T") })
            let grounded = try #require(reference.ir.nets.first { $0.name == NetName("S") })
            #expect(s.totalCouplingCapF > 0 && close(s.totalCouplingCapF, t.totalCouplingCapF))
            #expect(close(s.totalGroundCapF, 0.8448e-12) && close(t.totalGroundCapF, 0.8448e-12))
            #expect(close(grounded.totalGroundCapF, s.totalGroundCapF + s.totalCouplingCapF))
            #expect(grounded.totalCouplingCapF == 0)
            #expect(reference.ir.nets.count == 1)
            #expect(reference.ir.elements.allSatisfy { $0.kind != .coupling })
            #expect(signals.queryReceipts.contains {
                $0.context.kind == (diagonal ? .diagUnder : .over)
                    && ($0.couplingFarads > 0 || $0.fringeFarads > 0)
            })
            assertCapacitanceTotals(signals.ir)
            assertCapacitanceTotals(reference.ir)
        }
    }

    @Test func cancellationAndCumulativeQuotasNeverReturnPartialGraphs() throws {
        let fixture = try RoutedPEXFixture(), input = pair(fixture)
        #expect(throws: NativeRoutedPEXError.cancelled) {
            try calculate(input, fixture, isCancelled: { true })
        }
        let polls = Mutex(0)
        #expect(throws: NativeRoutedPEXError.cancelled) {
            try calculate(input, fixture, isCancelled: { polls.withLock { $0 += 1; return $0 >= 10 } })
        }
        let complete = try calculate(input, fixture)
        let work = quota(fixture.limits, work: complete.workVisitsConsumed - 1)
        #expect(throws: NativeRoutedPEXError.limitExceeded(.workVisits)) {
            try calculate(input, fixture, limits: work)
        }
        #expect(throws: NativeRoutedPEXError.limitExceeded(.graphElements)) {
            try calculate(input, fixture, limits: quota(fixture.limits, elements: 1))
        }
        #expect(throws: NativeRoutedPEXError.limitExceeded(.queryReceipts)) {
            try calculate(input, fixture, limits: quota(fixture.limits, queries: 1))
        }
        let retried = try calculate(input, fixture)
        #expect(retried.ir == complete.ir)
        #expect(retried.workVisitsConsumed == complete.workVisitsConsumed)
    }

    @Test func actualLandingOcclusionQueriesItsOwnExposedFaceBeforeConsumingTheInterval() throws {
        let fixture = try RoutedPEXFixture(), input = landingOcclusionInput(fixture)
        var queries = try exposureQueries(input, fixture)
        let source = try #require(queries.geometry.wires.firstIndex { $0.netName == NetName("S") })
        let buried = try #require(queries.geometry.wires.firstIndex {
            $0.netName == NetName("T") && $0.rect.minX == 8805 && $0.rect.maxX == 17415 && $0.rect.maxY == 3890
        })
        let exposed = try #require(queries.geometry.wires.firstIndex {
            $0.netName == NetName("T") && $0.rect.minX == 17085 && $0.rect.minY == 3890 && $0.rect.maxY == 3905
        })
        let span = NativeRoutedPEXGeometry.Interval(low: 17335, high: 17415)
        let event = NativeRoutedPEXEvents.Event(source: source, target: nil, span: span, gap: nil,
                                               group: 0, contextBase: 4430)
        let layer = try #require(queries.geometry.layers["li1"])
        try queries.prepareDiagonal(event, layer: layer, isCancelled: { false })
        try queries.diagonal(event, span: span, targetLevel: 4, isCancelled: { false })
        #expect(queries.queryReceipts.count == 1)
        let query = try #require(queries.queryReceipts.first)
        #expect(query.sourceIDs == [queries.geometry.wires[source].sourceID, queries.geometry.wires[exposed].sourceID])
        #expect(!query.sourceIDs.contains(queries.geometry.wires[buried].sourceID))
        #expect(query.requestedWidthDatabaseUnits == 170)
        #expect(query.requestedDistanceDatabaseUnits == 525)
        #expect(query.effectiveLengthDatabaseUnits == 80)
        #expect(queries.caps.count == 1 && queries.caps[0].b == exposed && queries.caps[0].span == span)
        // The complete composition must attach that freshly queried scalar to real landing cells.
        let result = try calculate(input, fixture, span: 1000)
        #expect(try #require(result.ir.nets.first { $0.name == NetName("S") }).totalCouplingCapF > 0)
        assertCapacitanceTotals(result.ir)
    }

    @Test func partialVisibilityClipsBothPhysicalFacesAndPreservesProjectedOverlap() throws {
        let fixture = try RoutedPEXFixture()
        for projected in [false, true] {
            let input = partialExposureInput(fixture, projected: projected)
            var queries = try exposureQueries(input, fixture)
            let source = try #require(queries.geometry.wires.firstIndex {
                $0.netName == NetName("S") && $0.rect.minY == 500 && $0.rect.maxY == 520
            })
            let target = try #require(queries.geometry.wires.firstIndex {
                $0.netName == NetName("T") && $0.rect.minY == (projected ? 500 : 300)
            })
            let span = NativeRoutedPEXGeometry.Interval(low: 200, high: 900)
            let eligible = try queries.geometry.exposedPairSpans(source: source, target: target,
                span: span, budget: &queries.budget, isCancelled: { false })
            let reverse = try queries.geometry.exposedPairSpans(source: target, target: source,
                span: span, budget: &queries.budget, isCancelled: { false })
            #expect(eligible == [projected ? span : .init(low: 400, high: 600)])
            #expect(reverse == eligible)
            if !projected {
                for hidden in [NativeRoutedPEXGeometry.Interval(low: 200, high: 300), .init(low: 700, high: 800)] {
                    #expect(try queries.geometry.exposedPairSpans(source: source, target: target,
                        span: hidden, budget: &queries.budget, isCancelled: { false }).isEmpty)
                }
                let visibleEvents = queries.search.events.filter { $0.source == target && $0.target == source }
                #expect(!visibleEvents.isEmpty)
                #expect(visibleEvents.allSatisfy { $0.span.low >= 400 && $0.span.high <= 600 })
            }
        }
    }

    @Test func exposedLandingQueryAndCompleteGraphAreIndependentOfSourceOrder() throws {
        let fixture = try RoutedPEXFixture(), input = landingOcclusionInput(fixture)
        let ordered = try calculate(input, fixture, span: 1000)
        let reversed = try calculate(fixture.replace(input, wires: input.wires.reversed(), nodes: input.nodes.reversed()),
                                     fixture, span: 1000)
        #expect(ordered.ir == reversed.ir)
        #expect(ordered.queryReceipts.count == reversed.queryReceipts.count)
        for (a, b) in zip(ordered.queryReceipts, reversed.queryReceipts) {
            #expect(a.sourceIDs == b.sourceIDs && a.context == b.context)
            #expect(a.requestedWidthDatabaseUnits == b.requestedWidthDatabaseUnits)
            #expect(a.requestedDistanceDatabaseUnits == b.requestedDistanceDatabaseUnits)
            #expect(a.effectiveLengthDatabaseUnits == b.effectiveLengthDatabaseUnits)
            #expect(a.couplingFarads == b.couplingFarads && a.fringeFarads == b.fringeFarads)
        }
    }

    private func exposureQueries(_ input: Input, _ fixture: RoutedPEXFixture) throws -> NativeRoutedPEXCalculation {
        var calculation = try UnionSheetRoutedPEXCalculation(input: input, model: fixture.model,
            groundModel: calibration(fixture), span: 1000, limits: fixture.limits)
        let geometry = try NativeRoutedPEXGeometry(input: input, model: fixture.model,
            budget: &calculation.budget, isCancelled: { false }, areaContacts: true)
        let sources = try calculation.unionSources({ false }), units = input.databaseUnitsPerMicron
        let union = try calculation.lower { accounting in
            try RectilinearConductorUnionBuilder().build(sources: sources, databaseUnitsPerMicron: units,
                accounting: &accounting, isCancelled: { false })
        }
        let wires = try calculation.queryWires(union: union, isCancelled: { false })
        return try NativeRoutedPEXCalculation(geometry: .init(admitted: geometry, queryWires: wires, conductorUnion: union),
            model: fixture.model, budget: &calculation.budget, isCancelled: { false })
    }

    private func landingOcclusionInput(_ fixture: RoutedPEXFixture) -> Input {
        let base = fixture.input([
            .init(id: "actual.LI", net: "S", layer: 1, x0: 17250, y0: 4515, x1: 17710, y1: 4515),
            .init(id: "actual.M3", net: "T", layer: 4, x0: 8970, y0: 3740, x1: 17250, y1: 3740),
            .init(id: "actual.leftLanding", net: "T", layer: 4, x0: 8900, y0: 3740, x1: 9050, y1: 3740),
            .init(id: "actual.rightLanding", net: "T", layer: 4, x0: 17150, y0: 3740, x1: 17350, y1: 3740)])
        let rectangles = [rect(17165, 4430, 17795, 4600), rect(8820, 3590, 17400, 3890),
                          rect(8805, 3575, 9135, 3905), rect(17085, 3575, 17415, 3905)]
        let wires = base.wires.enumerated().map { wire($0.element, rect: rectangles[$0.offset]) }
        let pitches: [Int64] = [460, 340, 460, 680, 920, 3400]
        let widths: [Int64] = [170, 140, 140, 300, 300, 1600]
        let layers = base.layers.enumerated().map { index, layer in
            Input.Layer(name: layer.name, level: layer.level, preferredDirection: layer.preferredDirection,
                pitchDatabaseUnits: pitches[index], defaultWidthDatabaseUnits: widths[index],
                sheetResistanceOhmsPerSquare: layer.sheetResistanceOhmsPerSquare,
                searchOriginX: 0, searchOriginY: 0, originDerivationX: .dieLowerLeft, originDerivationY: .dieLowerLeft,
                sourceFacts: layer.sourceFacts)
        }
        return .init(selection: base.selection, defArtifactID: base.defArtifactID, sourceArtifacts: base.sourceArtifacts,
            databaseUnitsPerMicron: base.databaseUnitsPerMicron, dieBounds: rect(0, 0, 18400, 8160), layers: layers,
            nets: base.nets, nodes: base.nodes, wires: wires, vias: [], terminals: base.terminals)
    }

    private func partialExposureInput(_ fixture: RoutedPEXFixture, projected: Bool) -> Input {
        let y: Int64 = projected ? 200 : 0, layer = projected ? 3 : 2
        let base = fixture.input([
            .init(id: "S.main", net: "S", x0: 105, y0: 510, x1: 995, y1: 510),
            .init(id: "S.lower", net: "S", x0: 105, y0: 490, x1: 395, y1: 490),
            .init(id: "T.main", net: "T", layer: layer, x0: 105, y0: 310 + y, x1: 995, y1: 310 + y),
            .init(id: "T.upper", net: "T", layer: layer, x0: 605, y0: 330 + y, x1: 995, y1: 330 + y)])
        let rectangles = [rect(100, 500, 1000, 520), rect(100, 480, 400, 500),
                          rect(100, 300 + y, 1000, 320 + y), rect(600, 320 + y, 1000, 340 + y)]
        return fixture.replace(base, wires: base.wires.enumerated().map { wire($0.element, rect: rectangles[$0.offset]) })
    }

    @Test func actualRuntimeAreaWeightsRetainCompensationAndEveryPositiveShare() throws {
        let allocation = try allocate([40_000, 200_000, 120_000, 40_000], farads: 4e-17, total: 400_000)
        #expect(Set(allocation.map(\.partIndex)) == Set(0..<4))
        #expect(allocation.allSatisfy { $0.farads.isFinite && $0.farads > 0 })
        #expect(try errorFreePositiveSum(allocation.map(\.farads)) == 4e-17)
        // The two equal physical end areas each receive exactly one tenth of the scalar.
        #expect(allocation.filter { $0.partIndex == 0 }.map(\.farads) == [4e-18])
        #expect(allocation.filter { $0.partIndex == 3 }.map(\.farads) == [4e-18])
    }

    @Test func highlyUnequalWeightsKeepSubUlpCapacityAndFiniteMaximumScalar() throws {
        let allocation = try allocate([UInt64.max - 1, 1], farads: 4e-17, total: UInt64.max)
        let tiny = try #require(allocation.first { $0.partIndex == 1 })
        #expect(tiny.farads > 0 && tiny.farads < Double(4e-17).ulp)
        #expect(allocation.allSatisfy { $0.farads.isFinite && $0.farads > 0 })
        #expect(try errorFreePositiveSum(allocation.map(\.farads)) == 4e-17)
        let largest = try allocate([1, 1], farads: Double.greatestFiniteMagnitude, total: 2)
        #expect(largest.allSatisfy { $0.farads.isFinite && $0.farads > 0 })
        #expect(try errorFreePositiveSum(largest.map(\.farads)) == Double.greatestFiniteMagnitude)
    }

    @Test func unrepresentablePositiveSharesAndOverflowRefuseInsteadOfLosingCapacity() throws {
        #expect(throws: NativeRoutedPEXError.unrepresentableArithmetic) {
            try allocate([1, 1], farads: Double.leastNonzeroMagnitude, total: 2)
        }
        #expect(throws: NativeRoutedPEXError.unrepresentableArithmetic) {
            try allocate([UInt64.max, 1], farads: 4e-17, total: UInt64.max)
        }
        for scalar in [Double.infinity, .nan] {
            #expect(throws: NativeRoutedPEXError.unrepresentableArithmetic) {
                try allocate([1, 1], farads: scalar, total: 2)
            }
        }
    }

    private func allocate(_ weights: [UInt64], farads: Double, total: UInt64) throws
        -> [UnionSheetRoutedPEXCalculation.AllocatedScalar] {
        let fixture = try RoutedPEXFixture()
        var calculation = try UnionSheetRoutedPEXCalculation(input: fixture.input([]), model: fixture.model,
            groundModel: calibration(fixture), span: 25, limits: fixture.limits)
        let parts = weights.enumerated().map {
            UnionSheetRoutedPEXCalculation.WeightedCells(a: $0.offset, b: nil, weight: $0.element, begin: nil, end: nil)
        }
        return try calculation.apportion(parts, farads: farads, expectedWeight: total, isCancelled: { false })
    }

    /// Independent nonoverlapping expansion using FastTwoSum, rather than the production Neumaier state.
    private func errorFreePositiveSum(_ values: [Double]) throws -> Double {
        var partials: [Double] = []
        for original in values {
            try #require(original.isFinite && original > 0)
            var x = original, next: [Double] = []
            for originalPartial in partials {
                var y = originalPartial
                if abs(x) < abs(y) { swap(&x, &y) }
                let high = x + y
                let low = y - (high - x)
                if low != 0 { next.append(low) }
                x = high
            }
            next.append(x); partials = next
        }
        return partials.reduce(0, +)
    }

    private func calculate(_ input: Input, _ fixture: RoutedPEXFixture, span: Int32 = 25,
                           limits: NativeRoutedPEXLimits? = nil,
                           isCancelled: @Sendable () -> Bool = { false }) throws -> NativeRoutedPEXResult {
        try UnionSheetRoutedPEXCalculator().calculate(input: input, model: fixture.model,
            groundCapacitanceModel: calibration(fixture), maximumCellSpanDatabaseUnits: span,
            cornerID: "tt", limits: limits ?? fixture.limits, isCancelled: isCancelled)
    }

    private func calibration(_ fixture: RoutedPEXFixture) -> PEXRoutedGroundCapacitanceModel {
        let ranges = [PEXOpenRCXSourceModel.SourceRange(lowerBound: 0, upperBound: 10)]
        return .init(selection: fixture.model.selection, cornerID: "tt", capacitanceUnitPicofarads: 1,
            unitSourceRanges: ranges, layers: fixture.model.selection.routingLayerNames.map {
                .init(name: $0, areaPicofaradsPerSquareMicron: 2, edgePicofaradsPerMicron: 3,
                    thicknessMicrons: nil, sourceRanges: ranges)
            })
    }

    private func rect(_ x0: Int64, _ y0: Int64, _ x1: Int64, _ y1: Int64) -> Input.Rect {
        .init(minX: x0, minY: y0, maxX: x1, maxY: y1)
    }

    private func wire(_ original: Input.Wire, id: String? = nil, ordinal: Int? = nil, rect: Input.Rect,
                      source: NodeRef? = nil, target: NodeRef? = nil) -> Input.Wire {
        .init(sourceID: id ?? original.sourceID, sourceOrdinal: ordinal ?? original.sourceOrdinal,
            netName: original.netName, layerName: original.layerName, axis: original.axis, rect: rect,
            sourceNode: source ?? original.sourceNode, targetNode: target ?? original.targetNode,
            sourceFacts: original.sourceFacts)
    }

    private func rectangle(_ fixture: RoutedPEXFixture) -> Input {
        let original = fixture.input([.init(id: "S", net: "S", x0: 105, y0: 100, x1: 215, y1: 100)])
        let conductor = wire(original.wires[0], rect: rect(100, 90, 220, 110))
        let terminals = original.terminals.enumerated().map { index, terminal in
            Input.Terminal(ref: terminal.ref, contacts: [.init(layerName: "met1",
                rect: index == 0 ? rect(100, 90, 110, 110) : rect(210, 90, 220, 110),
                sourceFacts: fixture.facts)], sourceFacts: fixture.facts)
        }
        return fixture.replace(original, wires: [conductor], terminals: terminals)
    }

    private func pair(_ fixture: RoutedPEXFixture, reference: Bool = false, diagonal: Bool = false) -> Input {
        let targetY: Int64 = diagonal ? 230 : 130
        let targetLayer = diagonal ? 3 : 2
        let original = fixture.input([
            .init(id: "S", net: "S", x0: 105, y0: 100, x1: 215, y1: 100),
            .init(id: "T", net: "T", role: reference ? .reference : .signal, layer: targetLayer,
                x0: 105, y0: targetY, x1: 215, y1: targetY)])
        let wires = original.wires.map { source in
            let y: Int64 = source.netName == NetName("S") ? 100 : targetY
            return wire(source, rect: rect(100, y - 10, 220, y + 10))
        }
        let terminals = original.terminals.map { terminal in
            let y: Int64 = terminal.ref.netName == NetName("S") ? 100 : targetY
            let left = terminal.ref.nodeName.value.hasSuffix(".a")
            return Input.Terminal(ref: terminal.ref, contacts: [.init(
                layerName: terminal.ref.netName == NetName("S") ? "met1" : (diagonal ? "met2" : "met1"),
                rect: left ? rect(100, y - 10, 110, y + 10) : rect(210, y - 10, 220, y + 10),
                sourceFacts: fixture.facts)], sourceFacts: fixture.facts)
        }
        return fixture.replace(original, wires: wires, terminals: terminals)
    }

    private func actualShortTurn(_ fixture: RoutedPEXFixture, cutOhms: Double?) -> Input {
        let base = fixture.input([])
        let a = NodeRef(netName: NetName("S"), nodeName: NodeName("A"))
        let junction = NodeRef(netName: a.netName, nodeName: NodeName("junction"))
        let b = NodeRef(netName: a.netName, nodeName: NodeName("B"))
        let top = NodeRef(netName: a.netName, nodeName: NodeName("upper"))
        let extensionRect = rect(17165, 5865, 17335, 5900)
        let contactA = Input.Landing(layerName: cutOhms == nil ? "met1" : "met2",
            rect: extensionRect, sourceFacts: fixture.facts)
        var nodes = [Input.Node(ref: a, layerName: "met1", x: 17250, y: 5882, sourceFacts: fixture.facts),
                     .init(ref: junction, layerName: "met1", x: 17250, y: 5985, sourceFacts: fixture.facts),
                     .init(ref: b, layerName: "met1", x: 17777, y: 5985, sourceFacts: fixture.facts)]
        let wires = [Input.Wire(sourceID: "wire28", sourceOrdinal: 0, netName: a.netName,
            layerName: "met1", axis: .horizontal, rect: rect(17165, 5900, 17795, 6070),
            sourceNode: junction, targetNode: b, sourceFacts: fixture.facts),
            .init(sourceID: "wire29", sourceOrdinal: 1, netName: a.netName, layerName: "met1", axis: .vertical,
                rect: rect(17165, 5865, 17335, 6070), sourceNode: a, targetNode: junction, sourceFacts: fixture.facts)]
        var vias: [Input.Via] = []
        if let cutOhms {
            nodes.append(.init(ref: top, layerName: "met2", x: 17250, y: 5882, sourceFacts: fixture.facts))
            vias = [.init(sourceID: "via35", sourceOrdinal: 2, netName: a.netName, sourceNode: a, targetNode: top,
                cuts: [.init(layerName: "via1", rect: extensionRect, resistanceOhms: cutOhms, sourceFacts: fixture.facts)],
                landings: [.init(layerName: "met1", rect: extensionRect, sourceFacts: fixture.facts), contactA],
                sourceFacts: fixture.facts)]
        }
        return .init(selection: base.selection, defArtifactID: base.defArtifactID, sourceArtifacts: base.sourceArtifacts,
            databaseUnitsPerMicron: base.databaseUnitsPerMicron, dieBounds: rect(0, 0, 30000, 30000),
            layers: base.layers, nets: [.init(name: a.netName, role: .signal, sourceFacts: fixture.facts)],
            nodes: nodes, wires: wires, vias: vias, terminals: [
                .init(ref: cutOhms == nil ? a : top, contacts: [contactA], sourceFacts: fixture.facts),
                .init(ref: b, contacts: [.init(layerName: "met1", rect: rect(17760, 5900, 17795, 6070),
                    sourceFacts: fixture.facts)], sourceFacts: fixture.facts)])
    }

    private func quota(_ original: NativeRoutedPEXLimits, work: Int? = nil, elements: Int? = nil,
                       queries: Int? = nil) -> NativeRoutedPEXLimits {
        .init(maximumInputRecords: original.maximumInputRecords, maximumStringBytes: original.maximumStringBytes,
            maximumSourceRecords: original.maximumSourceRecords, maximumWorkVisits: work ?? original.maximumWorkVisits,
            maximumTrackEntries: original.maximumTrackEntries, maximumCoordinateValues: original.maximumCoordinateValues,
            maximumGraphNodes: original.maximumGraphNodes, maximumGraphElements: elements ?? original.maximumGraphElements,
            maximumQueryReceipts: queries ?? original.maximumQueryReceipts)
    }

    private func close(_ actual: Double, _ expected: Double) -> Bool {
        abs(actual - expected) <= max(1e-28, abs(expected) * 1e-10)
    }

    private func assertCapacitanceTotals(_ ir: ParasiticIR) {
        #expect(ir.elements.allSatisfy { $0.value.isFinite && $0.value >= 0 })
        for net in ir.nets {
            let ground = ir.elements.filter { $0.kind == .capacitor && $0.nodeA.netName == net.name }.reduce(0) { $0 + $1.value }
            let coupling = ir.elements.filter {
                $0.kind == .coupling && ($0.nodeA.netName == net.name || $0.nodeB?.netName == net.name)
            }.reduce(0) { $0 + $1.value }
            #expect(close(net.totalGroundCapF, ground))
            #expect(close(net.totalCouplingCapF, coupling))
        }
        let physicalCC = ir.elements.filter { $0.kind == .coupling }.reduce(0) { $0 + $1.value }
        #expect(close(ir.nets.reduce(0) { $0 + $1.totalCouplingCapF }, 2 * physicalCC))
    }

    // Solve the emitted resistor graph at 1 V / 0 V, after collapsing explicit zero-ohm pin aliases.
    private func resistance(_ ir: ParasiticIR, from source: NodeRef, to target: NodeRef) throws -> Double {
        let edges = ir.elements.filter { $0.kind == .resistor && $0.nodeA.netName == source.netName }
        let net = try #require(ir.nets.first { $0.name == source.netName })
        let refs = net.nodes.map { NodeRef(netName: net.name, nodeName: $0.name) }
        let lookup = Dictionary(uniqueKeysWithValues: refs.enumerated().map { ($0.element, $0.offset) })
        var groups = Array(refs.indices)
        for edge in edges where edge.value == 0 {
            let a = groups[try #require(lookup[edge.nodeA])]
            let nodeB = try #require(edge.nodeB)
            let b = groups[try #require(lookup[nodeB])]
            for index in groups.indices where groups[index] == b { groups[index] = a }
        }
        let a = groups[try #require(lookup[source])], b = groups[try #require(lookup[target])]
        try #require(a != b && refs.count <= 512)
        let unknown = Set(groups).subtracting([a, b]).sorted()
        let index = Dictionary(uniqueKeysWithValues: unknown.enumerated().map { ($0.element, $0.offset) })
        let n = unknown.count
        var matrix = [Double](repeating: 0, count: n * n), rhs = [Double](repeating: 0, count: n)
        var conductors: [(Int, Int, Double)] = []
        for edge in edges where edge.value > 0 {
            let u = groups[try #require(lookup[edge.nodeA])]
            let nodeB = try #require(edge.nodeB)
            let v = groups[try #require(lookup[nodeB])]
            if u == v { continue }
            let g = 1 / edge.value
            try #require(g.isFinite && g > 0)
            conductors.append((u, v, g))
            for (x, y) in [(u, v), (v, u)] {
                if let i = index[x] {
                    matrix[i * n + i] += g
                    if let j = index[y] { matrix[i * n + j] -= g }
                    else if y == a { rhs[i] += g }
                }
            }
        }
        for column in 0..<n {
            let pivot = try #require((column..<n).max { abs(matrix[$0 * n + column]) < abs(matrix[$1 * n + column]) })
            try #require(abs(matrix[pivot * n + column]) > 1e-14)
            if pivot != column {
                for j in 0..<n { matrix.swapAt(column * n + j, pivot * n + j) }
                rhs.swapAt(column, pivot)
            }
            let divisor = matrix[column * n + column]
            for j in column..<n { matrix[column * n + j] /= divisor }
            rhs[column] /= divisor
            for row in (column + 1)..<n {
                let factor = matrix[row * n + column]
                for j in column..<n { matrix[row * n + j] -= factor * matrix[column * n + j] }
                rhs[row] -= factor * rhs[column]
            }
        }
        var voltage: [Int: Double] = [a: 1, b: 0]
        for row in (0..<n).reversed() {
            var value = rhs[row]
            for column in (row + 1)..<n { value -= matrix[row * n + column] * (try #require(voltage[unknown[column]])) }
            voltage[unknown[row]] = value
        }
        var current = 0.0
        for (u, v, g) in conductors {
            if u == a { current += (1 - (try #require(voltage[v]))) * g }
            else if v == a { current += (1 - (try #require(voltage[u]))) * g }
        }
        try #require(current.isFinite && current > 0)
        return 1 / current
    }
}
