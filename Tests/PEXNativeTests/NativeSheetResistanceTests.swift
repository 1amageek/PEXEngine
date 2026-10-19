import Testing
import Synchronization
import CircuiteFoundation
import PEXCore
@testable import PEXNative

@Suite("Material independent union sheet resistance", .timeLimit(.minutes(2)))
struct NativeSheetResistanceTests {
    typealias Rect = NativeConductorUnion.Rect
    private let net = NetName("N")
    private func rect(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> Rect {
        .init(minX: x0, minY: y0, maxX: x1, maxY: y1)
    }
    private func source(_ id: String, _ r: Rect, layer: String = "M1", netName: NetName = NetName("N")) -> NativeConductorUnion.Source {
        .init(sourceID: id, netName: netName, layerName: layer, rect: r, sourceFacts: [])
    }
    private func terminal(_ name: String, _ r: Rect, layer: String = "M1") -> NativeSheetResistanceInput.Terminal {
        .init(ref: .init(netName: net, nodeName: NodeName(name)), contacts: [.init(layerName: layer, rect: r)])
    }
    private func union(_ sources: [NativeConductorUnion.Source]) throws -> NativeConductorUnion {
        let artifact = try ArtifactID(digest: .init(algorithm: .sha256,
            hexadecimalValue: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), byteCount: 3)
        let facts = [NativeConductorUnion.SourceFact(artifactID: artifact, byteRange: .init(lowerBound: 0, upperBound: 3))]
        let attributed = sources.map { NativeConductorUnion.Source(sourceID: $0.sourceID, netName: $0.netName,
            layerName: $0.layerName, rect: $0.rect, sourceFacts: facts) }
        return try RectilinearConductorUnionBuilder().build(sources: attributed, databaseUnitsPerMicron: 1000,
            limits: .init(maximumInputRecords: 100_000, maximumStringBytes: 100_000,
                          maximumUnionBands: 10_000, maximumBoundarySegments: 10_000,
                          maximumContributorIndices: 100_000, maximumCoordinateValues: 10_000,
                          maximumWorkVisits: 1_000_000), isCancelled: { false })
    }
    private func limits(_ resource: NativeConductorResource? = nil, value: Int = 1) -> NativeSheetResistanceLimits {
        func ceiling(_ r: NativeConductorResource, _ ordinary: Int) -> Int { resource == r ? value : ordinary }
        return .init(maximumInputRecords: ceiling(.inputRecords, 100_000), maximumStringBytes: ceiling(.stringBytes, 100_000),
                     maximumContributorIndices: ceiling(.contributorIndices, 200_000), maximumCoordinateValues: ceiling(.coordinateValues, 10_000),
                     maximumMeshCells: ceiling(.meshCells, 10_000), maximumGraphNodes: ceiling(.graphNodes, 10_000),
                     maximumGraphElements: ceiling(.graphElements, 100_000), maximumWorkVisits: ceiling(.workVisits, 2_000_000))
    }
    private func calculate(_ input: NativeSheetResistanceInput, span: Int32 = 20,
                           limits: NativeSheetResistanceLimits? = nil) throws -> NativeSheetResistanceResult {
        let calculator: any NativeSheetResistanceCalculating = RectilinearSheetResistanceCalculator()
        return try calculator.calculate(input: input, maximumCellSpanDatabaseUnits: span,
                                        limits: limits ?? self.limits(), isCancelled: { false })
    }
    private func rectangle(rotated: Bool = false) throws -> NativeSheetResistanceInput {
        .init(conductorUnion: try union([source("wire", rotated ? rect(0, 0, 20, 120) : rect(0, 0, 120, 20))]),
              materials: [.init(layerName: "M1", sheetOhms: 1)], cuts: [], terminals: [
                terminal("A", rotated ? rect(0, 0, 20, 10) : rect(0, 0, 10, 20)),
                terminal("B", rotated ? rect(0, 110, 20, 120) : rect(110, 0, 120, 20))])
    }

    @Test func rectangleMatchesSheetLengthOverWidthAcrossRefinementAndOrientation() throws {
        for rotated in [false, true] {
            let input = try rectangle(rotated: rotated)
            for span: Int32 in [100, 25, 10] {
                let result = try calculate(input, span: span)
                #expect(abs(try resistance(result) - 5) < 1e-10)
                #expect(result.conductorUnion.sources == input.conductorUnion.sources)
                #expect(result.conductorUnion.bands == input.conductorUnion.bands)
                #expect(result.cells.allSatisfy { Int64($0.rect.maxX) - Int64($0.rect.minX) <= Int64(span)
                    && Int64($0.rect.maxY) - Int64($0.rect.minY) <= Int64(span) })
                #expect(result.resistors.allSatisfy { $0.ohms > 0 && $0.ohms.isFinite && (1 / $0.ohms).isFinite })
            }
        }
    }

    @Test func squareSymmetryAndFiniteContactHalfSpans() throws {
        let input = NativeSheetResistanceInput(conductorUnion: try union([source("square", rect(0, 0, 120, 100))]),
            materials: [.init(layerName: "M1", sheetOhms: 3)], cuts: [],
            terminals: [terminal("A", rect(0, 0, 10, 100)), terminal("B", rect(110, 0, 120, 100))])
        #expect(abs(try resistance(calculate(input, span: 100)) - 3) < 1e-10)
        let long = try calculate(rectangle(), span: 100)
        let contacts = long.resistors.filter { $0.kind == .contact }
        #expect(contacts.count == 2)
        #expect(contacts.allSatisfy { abs($0.ohms - 2.5) < 1e-14 })
        #expect(long.resistors.allSatisfy { $0.nodeA != $0.nodeB && $0.ohms > 0 })
    }

    @Test func lTurnUsesPhysicalUnionAndConvergesUnderRefinement() throws {
        let shape = try union([source("horizontal", rect(0, 0, 120, 20)), source("vertical", rect(100, 0, 120, 120))])
        let input = NativeSheetResistanceInput(conductorUnion: shape,
            materials: [.init(layerName: "M1", sheetOhms: 1)], cuts: [],
            terminals: [terminal("A", rect(0, 0, 10, 20)), terminal("B", rect(100, 110, 120, 120))])
        let coarse = try resistance(calculate(input, span: 20))
        let medium = try resistance(calculate(input, span: 10))
        let fine = try resistance(calculate(input, span: 5))
        #expect(coarse > 8 && coarse < 11)
        #expect(abs(fine - medium) < abs(medium - coarse))
        #expect(abs(fine - medium) < 0.15)
    }

    @Test func actualShortVerticalThirtyFiveDatabaseUnitWitnessIsConductive() throws {
        // Width 170 and square endcaps 85 preserve the actual 35-DBU extension.
        let geometry = try union([source("horizontal", rect(17165, 5900, 17795, 6070)),
                                  source("vertical", rect(17165, 5865, 17335, 6070))])
        let area = geometry.bands.reduce(Int64(0)) {
            $0 + (Int64($1.rect.maxX) - Int64($1.rect.minX)) * (Int64($1.rect.maxY) - Int64($1.rect.minY))
        }
        #expect(area == 630 * 170 + 35 * 170)
        let input = NativeSheetResistanceInput(conductorUnion: geometry, materials: [.init(layerName: "M1", sheetOhms: 0.2)],
            cuts: [], terminals: [terminal("A", rect(17165, 5865, 17335, 5900)), terminal("B", rect(17760, 5900, 17795, 6070))])
        let result = try calculate(input, span: 35)
        #expect(try resistance(result) > 0)
        #expect(result.cells.contains { $0.contributorIndices.count == 2 })
        #expect(result.cells.contains { $0.rect.minY == 5865 })
    }

    @Test func sourceReorderDuplicateAndSegmentationDoNotChangeRectangleResistance() throws {
        let a = source("A", rect(0, 0, 60, 20)), b = source("B", rect(60, 0, 120, 20))
        for records in [[a, b], [b, a], [a, b, source("A-duplicate", a.rect)], [source("whole", rect(0, 0, 120, 20))]] {
            let input = NativeSheetResistanceInput(conductorUnion: try union(records), materials: [.init(layerName: "M1", sheetOhms: 1)],
                cuts: [], terminals: [terminal("A", rect(0, 0, 10, 20)), terminal("B", rect(110, 0, 120, 20))])
            #expect(abs(try resistance(calculate(input, span: 25)) - 5) < 1e-10)
        }
    }

    @Test func eachCutPreservesAreaLawAndSourceIdentity() throws {
        let plate = rect(0, 0, 100, 100)
        let geometry = try union([source("lower", plate), source("upper", plate, layer: "M2")])
        for span: Int32 in [100, 50, 25] {
            let input = NativeSheetResistanceInput(conductorUnion: geometry, materials: [
                .init(layerName: "M1", sheetOhms: 1), .init(layerName: "M2", sheetOhms: 2)], cuts: [
                    .init(sourceID: "cutA", netName: net, lowerLayerName: "M1", upperLayerName: "M2", rect: plate, sourceOhms: 4),
                    .init(sourceID: "cutB", netName: net, lowerLayerName: "M1", upperLayerName: "M2", rect: plate, sourceOhms: 12)],
                terminals: [terminal("A", plate), terminal("B", plate, layer: "M2")])
            let result = try calculate(input, span: span)
            #expect(abs(try resistance(result) - 3) < 1e-10)
            #expect(result.nodes.filter { if case .cut = $0.kind { true } else { false } }.count == 2)
            for (id, value) in [("cutA", 4.0), ("cutB", 12.0)] {
                let halfEdges = result.resistors.filter { $0.kind == .cut(sourceID: id) }
                let lowerNode = result.terminalAssignments[0].nodeIndex
                let lowerConductance = halfEdges.filter { $0.nodeB == lowerNode }.reduce(0.0) { $0 + 1 / $1.ohms }
                #expect(abs(lowerConductance - 2 / value) < 1e-12)
            }
        }
    }

    @Test func coincidentContactsKeepEveryTerminalReference() throws {
        let original = try rectangle()
        let alias = terminal("ALIAS", rect(0, 0, 10, 20))
        let result = try calculate(.init(conductorUnion: original.conductorUnion, materials: original.materials,
            cuts: [], terminals: original.terminals + [alias]))
        #expect(result.terminalAssignments.count == 3)
        let a = try #require(result.terminalAssignments.first { $0.ref.nodeName.value == "A" })
        let other = try #require(result.terminalAssignments.first { $0.ref == alias.ref })
        #expect(a.nodeIndex == other.nodeIndex && a.cellIndices == other.cellIndices)
    }

    @Test func disconnectedContactsMissingCoverageAndIncompleteCutsRefuseSuccess() throws {
        let geometry = try union([source("left", rect(0, 0, 20, 20)), source("right", rect(40, 0, 60, 20))])
        let pin = terminal("A", rect(0, 0, 60, 20))
        let input = NativeSheetResistanceInput(conductorUnion: geometry, materials: [.init(layerName: "M1", sheetOhms: 1)],
            cuts: [], terminals: [pin])
        #expect(throws: NativeSheetResistanceError.disconnectedTerminal(pin.ref)) { try calculate(input) }
        let missing = terminal("MISSING", rect(25, 0, 35, 20))
        #expect(throws: NativeSheetResistanceError.missingTerminalContact(missing.ref)) {
            try calculate(.init(conductorUnion: geometry, materials: input.materials, cuts: [], terminals: [missing]))
        }
        let cut = NativeSheetResistanceInput.Cut(sourceID: "incomplete", netName: net,
            lowerLayerName: "M1", upperLayerName: "M2", rect: rect(0, 0, 20, 20), sourceOhms: 4)
        #expect(throws: NativeSheetResistanceError.incompleteCutContact(sourceID: "incomplete")) {
            try calculate(.init(conductorUnion: geometry, materials: input.materials + [.init(layerName: "M2", sheetOhms: 1)], cuts: [cut], terminals: []))
        }
    }

    @Test func actualThreeRectanglePortNeedsOnlyItsRealViaLandingIntersection() throws {
        let input = try threeRectanglePort()
        let result = try calculate(input, span: 170)
        #expect(abs(try resistance(result) - 4) < 1e-10)
        #expect(result.input.terminals[0].contacts.count == 3)
        #expect(result.input.terminals == input.terminals)
        let assignment = try #require(result.terminalAssignments.first { $0.ref == input.terminals[0].ref })
        #expect(!assignment.cellIndices.isEmpty)
        let landing = rect(1065, 2125, 1235, 2295)
        for index in assignment.cellIndices {
            let cell = result.cells[index]
            #expect(cell.layerName == "M1")
            #expect(cell.rect.minX >= landing.minX && cell.rect.maxX <= landing.maxX)
            #expect(cell.rect.minY >= landing.minY && cell.rect.maxY <= landing.maxY)
        }
        #expect(result.cells.filter { $0.layerName == "M1" }.allSatisfy {
            $0.rect.minX >= landing.minX && $0.rect.maxX <= landing.maxX
                && $0.rect.minY >= landing.minY && $0.rect.maxY <= landing.maxY
        })
        #expect(result.resistors.allSatisfy { $0.ohms.isFinite && $0.ohms > 0 })
    }

    @Test func unusedPortPatchesDoNotHideMissingForeignOrDisconnectedContact() throws {
        let original = try threeRectanglePort()
        let a = original.terminals[0]
        let absent = NativeSheetResistanceInput(conductorUnion: try union([
            source("remote", rect(5000, 5000, 5170, 5170))]), materials: original.materials,
            cuts: [], terminals: [a])
        #expect(throws: NativeSheetResistanceError.missingTerminalContact(a.ref)) { try calculate(absent, span: 170) }

        // This second patch is outside the contacted landing, and must still be inspected.
        let additional = rect(1140, 1000, 1240, 1100)
        let lower = source("lower", rect(1065, 2125, 1235, 2295))
        let upper = source("upper", rect(1005, 2095, 1295, 2325), layer: "M2")
        let foreign = NativeSheetResistanceInput(conductorUnion: try union([
            lower, upper, source("foreign", additional, netName: NetName("OTHER"))]),
            materials: original.materials, cuts: original.cuts, terminals: original.terminals)
        #expect(throws: NativeSheetResistanceError.invalidInput(reason: "Terminal contacts a foreign net.")) {
            try calculate(foreign, span: 170)
        }
        let disconnected = NativeSheetResistanceInput(conductorUnion: try union([
            lower, upper, source("island", additional)]), materials: original.materials,
            cuts: original.cuts, terminals: original.terminals)
        #expect(throws: NativeSheetResistanceError.disconnectedTerminal(a.ref)) { try calculate(disconnected, span: 170) }
    }

    private func threeRectanglePort() throws -> NativeSheetResistanceInput {
        // Exact DBU geometry of the retained buf_1 X PORT and L1M1_PR at (1150, 2210).
        let landing = rect(1065, 2125, 1235, 2295)
        let upper = rect(1005, 2095, 1295, 2325)
        let a = NativeSheetResistanceInput.Terminal(ref: .init(netName: net, nodeName: NodeName("A")), contacts: [
            .init(layerName: "M1", rect: rect(1025, 1560, 1295, 2465)),
            .init(layerName: "M1", rect: rect(1115, 760, 1295, 1560)),
            .init(layerName: "M1", rect: rect(1035, 255, 1295, 760))])
        return .init(conductorUnion: try union([source("lower", landing), source("upper", upper, layer: "M2")]),
            materials: [.init(layerName: "M1", sheetOhms: 1), .init(layerName: "M2", sheetOhms: 1)],
            cuts: [.init(sourceID: "L1M1_PR.cut", netName: net, lowerLayerName: "M1", upperLayerName: "M2",
                         rect: landing, sourceOhms: 4)], terminals: [a, terminal("B", upper, layer: "M2")])
    }

    @Test func cornerContactDoesNotConnectAndDifferentNetContactIsAShort() throws {
        let a = source("A", rect(0, 0, 20, 20)), b = source("B", rect(20, 20, 40, 40))
        let pin = terminal("A", rect(0, 0, 40, 40))
        let input = NativeSheetResistanceInput(conductorUnion: try union([a, b]), materials: [.init(layerName: "M1", sheetOhms: 1)],
            cuts: [], terminals: [pin])
        #expect(throws: NativeSheetResistanceError.disconnectedTerminal(pin.ref)) { try calculate(input) }
        #expect(throws: (any Error).self) { try union([a, source("foreign", rect(20, 0, 40, 20), netName: NetName("OTHER"))]) }
    }

    @Test func allFiniteCeilingsAndCancellationRefusePartialOutput() throws {
        let input = try rectangle()
        for resource: NativeConductorResource in [.inputRecords, .stringBytes, .contributorIndices, .coordinateValues,
                                                 .meshCells, .graphNodes, .graphElements, .workVisits] {
            #expect(throws: NativeSheetResistanceError.conductor(.limitExceeded(resource))) {
                try calculate(input, span: 10, limits: limits(resource))
            }
        }
        let calculator = RectilinearSheetResistanceCalculator()
        let checks = Mutex(0)
        var output: NativeSheetResistanceResult?
        #expect(throws: NativeSheetResistanceError.conductor(.cancelled)) {
            output = try calculator.calculate(input: input, maximumCellSpanDatabaseUnits: 10, limits: limits(), isCancelled: {
                checks.withLock { $0 += 1; return $0 == 60 }
            })
        }
        #expect(output == nil && checks.withLock { $0 } == 60)
        #expect(throws: NativeSheetResistanceError.invalidConfiguration) { try calculate(input, span: 0) }
        #expect(throws: NativeSheetResistanceError.invalidConfiguration) { try calculate(input, limits: limits(.meshCells, value: 0)) }
    }

    @Test func cumulativeLedgerKeepsSpentWorkAfterFailure() throws {
        var ledger: any NativeConductorResourceAccounting = try NativeSheetResistanceBudget(limits(.graphNodes))
        let before = ledger.remaining(.workVisits)
        let calculator = RectilinearSheetResistanceCalculator(), input = try rectangle()
        #expect(throws: NativeSheetResistanceError.conductor(.limitExceeded(.graphNodes))) {
            try calculator.calculate(input: input, maximumCellSpanDatabaseUnits: 10, accounting: &ledger, isCancelled: { false })
        }
        #expect(ledger.remaining(.workVisits) < before)
        #expect(ledger.remaining(.graphNodes) == 0)
    }

    // Independently assemble and solve the bounded nodal Kirchhoff system with fixed terminal voltages.
    private func resistance(_ graph: NativeSheetResistanceResult) throws -> Double {
        let a = try #require(graph.terminalAssignments.first { $0.ref.nodeName.value == "A" }?.nodeIndex)
        let b = try #require(graph.terminalAssignments.first { $0.ref.nodeName.value == "B" }?.nodeIndex)
        try #require(a != b && graph.nodes.count <= 512)
        let unknown = graph.nodes.indices.filter { $0 != a && $0 != b }
        let lookup = Dictionary(uniqueKeysWithValues: unknown.enumerated().map { ($0.element, $0.offset) })
        let n = unknown.count
        var matrix = [Double](repeating: 0, count: n * n), rhs = [Double](repeating: 0, count: n)
        for edge in graph.resistors {
            let conductance = 1 / edge.ohms
            for (u, v) in [(edge.nodeA, edge.nodeB), (edge.nodeB, edge.nodeA)] {
                if let i = lookup[u] {
                    matrix[i * n + i] += conductance
                    if let j = lookup[v] { matrix[i * n + j] -= conductance }
                    else if v == a { rhs[i] += conductance }
                }
            }
        }
        for column in 0..<n {
            let pivot = try #require((column..<n).max { abs(matrix[$0 * n + column]) < abs(matrix[$1 * n + column]) })
            try #require(matrix[pivot * n + column].isFinite && abs(matrix[pivot * n + column]) > 1e-14)
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
        var voltage = [Double](repeating: 0, count: graph.nodes.count); voltage[a] = 1
        for row in (0..<n).reversed() {
            var value = rhs[row]
            for column in (row + 1)..<n { value -= matrix[row * n + column] * voltage[unknown[column]] }
            voltage[unknown[row]] = value
        }
        var current = 0.0
        for edge in graph.resistors {
            if edge.nodeA == a { current += (1 - voltage[edge.nodeB]) / edge.ohms }
            else if edge.nodeB == a { current += (1 - voltage[edge.nodeA]) / edge.ohms }
        }
        try #require(current.isFinite && current > 0)
        return 1 / current
    }
}
