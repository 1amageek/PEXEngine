import CircuiteFoundation
import PEXCore
import Synchronization
import Testing
@testable import PEXNative

@Suite("Exact source-bound conductor union", .timeLimit(.minutes(1)))
struct NativeConductorUnionTests {
    private typealias Rect = NativeConductorUnion.Rect
    private typealias Source = NativeConductorUnion.Source
    private let limits = NativeConductorUnionLimits(maximumInputRecords: 10_000,
        maximumStringBytes: 100_000, maximumUnionBands: 10_000,
        maximumBoundarySegments: 10_000, maximumContributorIndices: 100_000,
        maximumCoordinateValues: 10_000, maximumWorkVisits: 1_000_000)

    @Test func rectangleHasExactAreaAndAllFourPhysicalFaces() throws {
        let source = try source("rectangle", rect: rect(-2, -1, 4, 3))
        let union = try build([source])
        #expect(union.databaseUnitsPerMicron == 1000)
        #expect(area(union) == 24)
        #expect(perimeter(union) == 20)
        #expect(union.boundaries.count == 4)
        #expect(Set(union.boundaries.map(\.side)) == Set([.minX, .maxX, .minY, .maxY]))
        assertExactUnitCoverage(union)
    }

    @Test func actualShortTurnPreservesOverlappingSourcesWithoutCountingOverlapTwice() throws {
        let horizontal = try source("wire28", rect: rect(17165, 5900, 17795, 6070))
        let vertical = try source("wire29", rect: rect(17165, 5865, 17335, 6070))
        let union = try build([horizontal, vertical])
        // Inclusion-exclusion: 630*170 + 170*205 - 170*170.
        #expect(area(union) == 113_050)
        // The six physical edges have lengths 170, 35, 460, 170, 630, 205.
        #expect(perimeter(union) == 1_670)
        #expect(union.sources == [horizontal, vertical])
        #expect(union.bands.contains { contributorIDs($0.contributorIndices, union) == Set(["wire28", "wire29"]) })
        assertBandContributors(union)
        assertBoundaryOwners(union)
    }

    @Test func sourceOrderDuplicatesAndSubdivisionPreservePhysicalCoverageAndAllProvenance() throws {
        let whole = try source("whole", rect: rect(0, 0, 6, 4))
        let left = try source("left", rect: rect(0, 0, 2, 4))
        let right = try source("right", rect: rect(2, 0, 6, 4))
        let duplicate = try source("duplicate", rect: whole.rect)
        let inputs = [[whole], [left, right], [right, left], [whole, duplicate], [duplicate, whole, left, right]]
        for input in inputs {
            let union = try build(input)
            #expect(area(union) == 24)
            #expect(perimeter(union) == 20)
            #expect(Set(union.sources.map(\.sourceID)) == Set(input.map(\.sourceID)))
            #expect(Set(union.sources.flatMap(\.sourceFacts)) == Set(input.flatMap(\.sourceFacts)))
            assertExactUnitCoverage(union)
        }
        let forward = try build([whole, left, right, duplicate])
        let reversed = try build([duplicate, right, left, whole])
        #expect(forward.sources == reversed.sources)
        #expect(forward.bands == reversed.bands)
        #expect(forward.boundaries == reversed.boundaries)
    }

    @Test func holeContainsBothOuterAndInnerPhysicalBoundaryWithOppositeFaces() throws {
        let union = try build([
            source("bottom", rect: rect(0, 0, 6, 2)),
            source("top", rect: rect(0, 4, 6, 6)),
            source("left", rect: rect(0, 2, 2, 4)),
            source("right", rect: rect(4, 2, 6, 4))
        ])
        #expect(area(union) == 32)
        #expect(perimeter(union) == 32)
        let inner = union.boundaries.filter {
            ($0.side == .maxY && $0.coordinate == 2 && $0.begin >= 2 && $0.end <= 4)
                || ($0.side == .minY && $0.coordinate == 4 && $0.begin >= 2 && $0.end <= 4)
                || ($0.side == .maxX && $0.coordinate == 2 && $0.begin >= 2 && $0.end <= 4)
                || ($0.side == .minX && $0.coordinate == 4 && $0.begin >= 2 && $0.end <= 4)
        }
        #expect(inner.count == 4)
        #expect(inner.reduce(Int64(0)) { $0 + Int64($1.end) - Int64($1.begin) } == 8)
        assertExactUnitCoverage(union)
    }

    @Test func cornerContactKeepsIslandsWhilePositiveEdgeContactRemovesInternalFace() throws {
        let first = try source("first", rect: rect(0, 0, 2, 2))
        let corner = try source("corner", rect: rect(2, 2, 4, 4))
        let cornerUnion = try build([first, corner])
        #expect(area(cornerUnion) == 8)
        #expect(perimeter(cornerUnion) == 16)
        assertExactUnitCoverage(cornerUnion)
        let edge = try source("edge", rect: rect(2, 0, 4, 2))
        let edgeUnion = try build([first, edge])
        #expect(area(edgeUnion) == 8)
        #expect(perimeter(edgeUnion) == 12)
        assertExactUnitCoverage(edgeUnion)
    }

    @Test func differentNetsRejectAreaAndEdgeShortsButAllowCornerAndDifferentLayers() throws {
        let first = try source("first", rect: rect(0, 0, 2, 2))
        for otherRect in [rect(1, 1, 3, 3), rect(2, 0, 4, 2)] {
            let other = try source("other", net: "OTHER", rect: otherRect)
            #expect(throws: NativeConductorError.shortCircuit(sourceIDs: ["first", "other"])) {
                try build([first, other])
            }
        }
        let corner = try source("corner", net: "OTHER", rect: rect(2, 2, 4, 4))
        let separated = try build([first, corner])
        #expect(area(separated) == 8)
        #expect(perimeter(separated) == 16)
        assertExactUnitCoverage(separated)
        let upper = try source("upper", net: "OTHER", layer: "met2", rect: first.rect)
        let stacked = try build([first, upper])
        #expect(area(stacked) == 8)
        #expect(perimeter(stacked) == 16)
        assertExactUnitCoverage(stacked)
    }

    @Test func malformedSourcesAndUnitsAreTypedFailures() throws {
        let valid = try source("valid", rect: rect(0, 0, 2, 2))
        assertInvalid { try build([]) }
        for units in [Int64(0), -1] {
            assertInvalid { try build([valid], units: units) }
        }
        for badRect in [rect(0, 0, 0, 2), rect(0, 0, 2, 0), rect(2, 0, 0, 2), rect(0, 2, 2, 0)] {
            let malformed = try source("bad", rect: badRect)
            assertInvalid { try build([malformed]) }
        }
        for name in ["", " "] {
            let badID = try source(name, rect: valid.rect)
            assertInvalid { try build([badID]) }
            let badNet = try source("bad", net: name, rect: valid.rect)
            assertInvalid { try build([badNet]) }
            let badLayer = try source("bad", layer: name, rect: valid.rect)
            assertInvalid { try build([badLayer]) }
        }
        assertInvalid { try build([valid, valid]) }
        let missingFacts = Source(sourceID: "missing", netName: valid.netName, layerName: valid.layerName,
            rect: valid.rect, sourceFacts: [])
        assertInvalid { try build([missingFacts]) }
        for range in [(-1, 1), (0, 0), (2, 1), (0, 4)] {
            let invalidFact = NativeConductorUnion.SourceFact(artifactID: try artifact(),
                byteRange: .init(lowerBound: range.0, upperBound: range.1))
            let invalid = Source(sourceID: "range", netName: valid.netName, layerName: valid.layerName,
                rect: valid.rect, sourceFacts: [invalidFact])
            assertInvalid { try build([invalid]) }
        }
    }

    @Test func everyOwnedBudgetAndCancellationRefuseTheWholeBuild() throws {
        let sources = try [source("horizontal", rect: rect(0, 1, 6, 3)),
                           source("vertical", rect: rect(0, 0, 2, 3))]
        for resource in [NativeConductorResource.inputRecords, .stringBytes, .unionBands,
                         .boundarySegments, .contributorIndices, .coordinateValues, .workVisits] {
            let bounded = NativeConductorUnionLimits(
                maximumInputRecords: resource == .inputRecords ? 1 : limits.maximumInputRecords,
                maximumStringBytes: resource == .stringBytes ? 1 : limits.maximumStringBytes,
                maximumUnionBands: resource == .unionBands ? 1 : limits.maximumUnionBands,
                maximumBoundarySegments: resource == .boundarySegments ? 1 : limits.maximumBoundarySegments,
                maximumContributorIndices: resource == .contributorIndices ? 1 : limits.maximumContributorIndices,
                maximumCoordinateValues: resource == .coordinateValues ? 1 : limits.maximumCoordinateValues,
                maximumWorkVisits: resource == .workVisits ? 1 : limits.maximumWorkVisits)
            #expect(throws: NativeConductorError.limitExceeded(resource)) {
                try build(sources, bounded: bounded)
            }
        }
        #expect(throws: NativeConductorError.cancelled) {
            try RectilinearConductorUnionBuilder().build(sources: sources, databaseUnitsPerMicron: 1000,
                limits: limits, isCancelled: { true })
        }
        let polls = Mutex(0)
        #expect(throws: NativeConductorError.cancelled) {
            try RectilinearConductorUnionBuilder().build(sources: sources, databaseUnitsPerMicron: 1000,
                limits: limits, isCancelled: { polls.withLock { $0 += 1; return $0 >= 3 } })
        }
        let recovered = try build(sources)
        #expect(area(recovered) == 14)
        #expect(perimeter(recovered) == 18)
        assertExactUnitCoverage(recovered)
    }

    private func build(_ sources: [Source], units: Int64 = 1000,
                       bounded: NativeConductorUnionLimits? = nil) throws -> NativeConductorUnion {
        try RectilinearConductorUnionBuilder().build(sources: sources, databaseUnitsPerMicron: units,
            limits: bounded ?? limits, isCancelled: { false })
    }

    private func artifact() throws -> ArtifactID {
        // SHA-256 of the exact three UTF-8 bytes "abc".
        try ArtifactID(digest: .init(algorithm: .sha256,
            hexadecimalValue: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), byteCount: 3)
    }

    private func source(_ id: String, net: String = "SIGNAL", layer: String = "met1", rect: Rect) throws -> Source {
        .init(sourceID: id, netName: NetName(net), layerName: layer, rect: rect,
            sourceFacts: [.init(artifactID: try artifact(), byteRange: .init(lowerBound: 0, upperBound: 3))])
    }

    private func rect(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> Rect {
        .init(minX: x0, minY: y0, maxX: x1, maxY: y1)
    }

    private func area(_ union: NativeConductorUnion) -> Int64 {
        union.bands.reduce(0) { $0 + (Int64($1.rect.maxX) - Int64($1.rect.minX))
            * (Int64($1.rect.maxY) - Int64($1.rect.minY)) }
    }

    private func perimeter(_ union: NativeConductorUnion) -> Int64 {
        union.boundaries.reduce(0) { $0 + Int64($1.end) - Int64($1.begin) }
    }

    private func contributorIDs(_ indices: [Int], _ union: NativeConductorUnion) -> Set<String> {
        Set(indices.filter { union.sources.indices.contains($0) }.map { union.sources[$0].sourceID })
    }

    private func assertInvalid(_ operation: () throws -> NativeConductorUnion) {
        do {
            _ = try operation()
            Issue.record("Malformed union input was accepted")
        } catch let error as NativeConductorError {
            guard case .invalidInput = error else { Issue.record("Expected invalid input, received \(error)"); return }
        } catch { Issue.record("Unexpected error type: \(error)") }
    }

    private func assertBandContributors(_ union: NativeConductorUnion) {
        for band in union.bands {
            #expect(band.rect.minX < band.rect.maxX && band.rect.minY < band.rect.maxY)
            #expect(band.contributorIndices == Array(Set(band.contributorIndices)).sorted())
            #expect(band.contributorIndices.allSatisfy { union.sources.indices.contains($0) })
            let expected = union.sources.filter { source in
                source.netName == band.netName && source.layerName == band.layerName
                    && source.rect.minX < band.rect.maxX && source.rect.maxX > band.rect.minX
                    && source.rect.minY < band.rect.maxY && source.rect.maxY > band.rect.minY
            }
            #expect(contributorIDs(band.contributorIndices, union) == Set(expected.map(\.sourceID)))
            let xCuts = Set([band.rect.minX, band.rect.maxX] + expected.flatMap {
                [max(band.rect.minX, $0.rect.minX), min(band.rect.maxX, $0.rect.maxX)]
            }).sorted()
            let yCuts = Set([band.rect.minY, band.rect.maxY] + expected.flatMap {
                [max(band.rect.minY, $0.rect.minY), min(band.rect.maxY, $0.rect.maxY)]
            }).sorted()
            for (x0, x1) in zip(xCuts, xCuts.dropFirst()) {
                for (y0, y1) in zip(yCuts, yCuts.dropFirst()) {
                    let doubledX = Int64(x0) + Int64(x1), doubledY = Int64(y0) + Int64(y1)
                    #expect(expected.contains {
                        2 * Int64($0.rect.minX) < doubledX && doubledX < 2 * Int64($0.rect.maxX)
                            && 2 * Int64($0.rect.minY) < doubledY && doubledY < 2 * Int64($0.rect.maxY)
                    })
                }
            }
        }
    }

    private func assertBoundaryOwners(_ union: NativeConductorUnion) {
        for boundary in union.boundaries {
            #expect(boundary.begin < boundary.end)
            guard union.bands.indices.contains(boundary.bandIndex) else {
                Issue.record("Boundary has no owning band"); continue
            }
            let band = union.bands[boundary.bandIndex]
            #expect(boundary.netName == band.netName && boundary.layerName == band.layerName)
            #expect(boundary.contributorIndices == band.contributorIndices)
            let vertical = boundary.side == .minX || boundary.side == .maxX
            let expectedCoordinate: Int32
            switch boundary.side {
            case .minX: expectedCoordinate = band.rect.minX
            case .maxX: expectedCoordinate = band.rect.maxX
            case .minY: expectedCoordinate = band.rect.minY
            case .maxY: expectedCoordinate = band.rect.maxY
            }
            #expect(boundary.coordinate == expectedCoordinate)
            #expect(boundary.begin >= (vertical ? band.rect.minY : band.rect.minX))
            #expect(boundary.end <= (vertical ? band.rect.maxY : band.rect.maxX))
        }
    }

    private struct Cell: Hashable { let net: NetName; let layer: String; let x: Int32; let y: Int32 }
    private struct Edge: Hashable {
        let net: NetName; let layer: String
        let side: NativeConductorUnion.Boundary.Side
        let coordinate: Int32; let begin: Int32
    }

    private func assertExactUnitCoverage(_ union: NativeConductorUnion) {
        assertBandContributors(union)
        assertBoundaryOwners(union)
        var expectedCells = Set<Cell>()
        for source in union.sources {
            for x in source.rect.minX..<source.rect.maxX { for y in source.rect.minY..<source.rect.maxY {
                expectedCells.insert(Cell(net: source.netName, layer: source.layerName, x: x, y: y))
            } }
        }
        var actualCells = Set<Cell>()
        for band in union.bands {
            for x in band.rect.minX..<band.rect.maxX { for y in band.rect.minY..<band.rect.maxY {
                #expect(actualCells.insert(Cell(net: band.netName, layer: band.layerName, x: x, y: y)).inserted)
            } }
        }
        #expect(actualCells == expectedCells)
        var expectedEdges = Set<Edge>()
        for cell in expectedCells {
            let neighbors: [(Int32, Int32, NativeConductorUnion.Boundary.Side, Int32, Int32)] = [
                (cell.x - 1, cell.y, .minX, cell.x, cell.y),
                (cell.x + 1, cell.y, .maxX, cell.x + 1, cell.y),
                (cell.x, cell.y - 1, .minY, cell.y, cell.x),
                (cell.x, cell.y + 1, .maxY, cell.y + 1, cell.x)
            ]
            for (x, y, side, coordinate, begin) in neighbors {
                if !expectedCells.contains(Cell(net: cell.net, layer: cell.layer, x: x, y: y)) {
                    expectedEdges.insert(Edge(net: cell.net, layer: cell.layer, side: side, coordinate: coordinate, begin: begin))
                }
            }
        }
        var actualEdges = Set<Edge>()
        for boundary in union.boundaries { for begin in boundary.begin..<boundary.end {
            #expect(actualEdges.insert(Edge(net: boundary.netName, layer: boundary.layerName,
                side: boundary.side, coordinate: boundary.coordinate, begin: begin)).inserted)
        } }
        #expect(actualEdges == expectedEdges)
    }
}
