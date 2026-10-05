import Foundation
import Testing
import PEXCore
import LayoutCore
import LayoutTech
import LayoutVerify
@testable import PEXNative

@Suite("Explicit sheet electrode construction", .timeLimit(.minutes(1)))
struct NativePEXElectrodeTests {
    private let fixture = NativePEXTestFixture()
    private func terminal(_ name: String) -> NodeRef { .init(netName: NetName("SIGNAL"), nodeName: NodeName(name)) }
    private func binding(_ index: Int, side: NativePEXElectrodeFace.Side, coordinate: Int32,
                         begin: Int32 = 0, end: Int32 = 2000) -> NativePEXElectrodeBinding {
        .init(pinIndex: index, terminal: terminal(index == 0 ? "A" : "B"),
              faces: [.init(side: side, coordinate: coordinate, begin: begin, end: end)])
    }
    private func network(_ cell: LayoutCell, span: Int32 = 2000, technology: TechnologyIR? = nil) throws -> NativePEXNetwork {
        let captured = try fixture.snapshot(cell)
        // These fixtures all contain selected centered pins: one native unit is 0.5 nm.
        #expect(captured.coordinateUnits.scale.databaseUnitsPerMicrometer == 2000)
        #expect(captured.hierarchy.units.scale.databaseUnitsPerMicrometer == 1000)
        return try RectilinearPEXCalculator().calculate(snapshot: captured, technology: technology ?? fixture.technology(),
            corner: PEXCorner(id: "tt"), layerNames: fixture.bindings, maximumCellSpanDatabaseUnits: span)
    }
    private func rectangle(length: Double = 3, width: Double = 1, segmentedPins: Bool = false) -> LayoutCell {
        let net = UUID()
        var metal = fixture.rect(0, 0, length, width); metal.netID = net
        let pinWidth = segmentedPins ? 0.5 : length
        return LayoutCell(name: "SHEET", shapes: [metal], pins: [
            LayoutPin(name: "A", position: .init(x: pinWidth / 2, y: width / 2), size: .init(width: pinWidth, height: width), layer: fixture.m1, netID: net),
            LayoutPin(name: "B", position: .init(x: length - pinWidth / 2, y: width / 2), size: .init(width: pinWidth, height: width), layer: fixture.m1, netID: net)])
    }
    private func build(_ source: NativePEXNetwork, _ bindings: [NativePEXElectrodeBinding], limits: NativePEXElectrodeLimits = .default)
        throws -> NativePEXElectrodeNetwork {
        let builder: any NativePEXElectrodeBuilding = RectilinearPEXElectrodeBuilder()
        return try builder.build(network: source, bindings: bindings, limits: limits, isCancelled: { Task.isCancelled })
    }

    @Test func oneCellNeedsTwoHalfCellContactsForFullTerminalResistance() throws {
        let source = try network(rectangle(length: 1))
        #expect(source.nodes.count == 1 && source.resistors.isEmpty)
        let output = try build(source, [binding(0, side: .minX, coordinate: 0), binding(1, side: .maxX, coordinate: 2000)])
        #expect(output.contacts.count == 2 && output.contacts.allSatisfy { abs($0.ohms - 0.01) < 1e-15 })
        #expect(abs(try resistance(output) - 0.02) < 1e-14)
        #expect(output.network.nodes == source.nodes && output.network.resistors == source.resistors && output.network.capacitors == source.capacitors)
    }

    @Test func analyticalTerminalResistanceSurvivesNonuniformAndRefinedMeshes() throws {
        for segmented in [false, true] {
            for span: Int32 in [2000, 1000, 500] {
                let output = try build(network(rectangle(segmentedPins: segmented), span: span),
                    [binding(0, side: .minX, coordinate: 0), binding(1, side: .maxX, coordinate: 6000)])
                #expect(abs(try resistance(output) - 0.06) < 1e-12)
                #expect(output.ports[0].componentIndex == output.ports[1].componentIndex)
            }
        }
    }

    @Test func yNormalElectrodesUseTheCorrectLengthAndWidth() throws {
        let output = try build(network(rectangle(length: 1, width: 3), span: 1000),
            [binding(0, side: .minY, coordinate: 0), binding(1, side: .maxY, coordinate: 6000)])
        #expect(abs(try resistance(output) - 0.06) < 1e-12)
    }

    @Test func adjacentFaceFragmentsAreParallelContactsWithoutDuplicateCoverage() throws {
        let source = try network(rectangle(length: 1))
        let a = NativePEXElectrodeBinding(pinIndex: 0, terminal: terminal("A"), faces: [
            .init(side: .minX, coordinate: 0, begin: 0, end: 1000),
            .init(side: .minX, coordinate: 0, begin: 1000, end: 2000)])
        let result = try build(source, [a, binding(1, side: .maxX, coordinate: 2000)])
        #expect(result.contacts.count == 3)
        #expect(abs(try resistance(result) - 0.02) < 1e-14)
    }

    @Test func pinAcrossDisconnectedIslandsCannotImposeOnePotential() throws {
        let pin = LayoutPin(name: "P", position: .init(x: 2, y: 0.5), size: .init(width: 4, height: 1), layer: fixture.m1, netID: UUID())
        let source = try network(LayoutCell(name: "ISLANDS", shapes: [fixture.rect(0, 0, 1, 1), fixture.rect(3, 0, 1, 1)], pins: [pin]))
        let builder = RectilinearPEXElectrodeBuilder()
        var output: NativePEXElectrodeNetwork?
        #expect(throws: NativePEXElectrodeError.ambiguousPinContact(pinIndex: 0, componentIndices: [0, 1])) {
            output = try builder.build(network: source, bindings: [binding(0, side: .minX, coordinate: 0)])
        }
        #expect(output == nil && source.resistors.isEmpty && source.snapshot.opens.count == 1)
    }

    @Test func uncontactedPinRemainsAnIsolatedPort() throws {
        let pin = LayoutPin(name: "OPEN", position: .init(x: 3, y: 0.5), size: .init(width: 1, height: 1), layer: fixture.m1, netID: UUID())
        let source = try network(LayoutCell(name: "OPEN", shapes: [fixture.rect(0, 0, 1, 1)], pins: [pin]))
        let output = try build(source, [.init(pinIndex: 0, terminal: terminal("OPEN"), faces: [])])
        #expect(output.ports.count == 1 && output.ports[0].componentIndex == nil && output.contacts.isEmpty)
        #expect(output.network.snapshot.opens == source.snapshot.opens && source.snapshot.opens.count == 1)
        #expect(throws: NativePEXElectrodeError.uncoveredFace(pinIndex: 0, faceIndex: 0)) {
            try build(source, [binding(0, side: .minX, coordinate: 0)])
        }
    }

    @Test func physicalShortKeepsDistinctPortsAndOriginalTopology() throws {
        var cell = rectangle(segmentedPins: true)
        let other = UUID()
        cell.pins[1].netID = other
        var extra = fixture.rect(2, 0, 1, 1); extra.netID = other; cell.shapes.append(extra)
        let source = try network(cell)
        #expect(source.snapshot.shortComponentIndices == [0])
        let output = try build(source, [binding(0, side: .minX, coordinate: 0),
            .init(pinIndex: 1, terminal: .init(netName: NetName("OTHER"), nodeName: NodeName("B")),
                  faces: [.init(side: .maxX, coordinate: 6000, begin: 0, end: 2000)])])
        #expect(output.network.snapshot.shortComponentIndices == [0] && output.ports.count == 2)
        #expect(abs(try resistance(output) - 0.06) < 1e-12)
    }

    @Test func missingDuplicateAndEmptyBindingsFail() throws {
        let source = try network(rectangle(length: 1))
        let a = binding(0, side: .minX, coordinate: 0), b = binding(1, side: .maxX, coordinate: 2000)
        #expect(throws: NativePEXElectrodeError.missingBinding(pinIndex: 1)) { try build(source, [a]) }
        #expect(throws: NativePEXElectrodeError.invalidBinding(pinIndex: 0)) { try build(source, [a, a, b]) }
        #expect(throws: NativePEXElectrodeError.duplicateTerminal) {
            try build(source, [a, .init(pinIndex: 1, terminal: a.terminal, faces: b.faces)])
        }
        #expect(throws: NativePEXElectrodeError.invalidBinding(pinIndex: 0)) {
            try build(source, [.init(pinIndex: 0, terminal: .init(netName: NetName(" "), nodeName: NodeName("A")), faces: a.faces), b])
        }
    }

    @Test func interiorWrongSideAndUncoveredFacesFailAtomically() throws {
        let source = try network(rectangle(length: 1), span: 1000)
        for face in [NativePEXElectrodeFace(side: .minX, coordinate: 1000, begin: 0, end: 2000),
                     .init(side: .maxX, coordinate: 0, begin: 0, end: 2000),
                     .init(side: .minX, coordinate: 0, begin: -2, end: 2000)] {
            let builder = RectilinearPEXElectrodeBuilder()
            var output: NativePEXElectrodeNetwork?
            #expect(throws: NativePEXElectrodeError.uncoveredFace(pinIndex: 0, faceIndex: 0)) {
                output = try builder.build(network: source, bindings: [.init(pinIndex: 0, terminal: terminal("A"), faces: [face]), binding(1, side: .maxX, coordinate: 2000)])
            }
            #expect(output == nil)
        }
    }

    @Test func electrodeCoverageMustBelongToThePinBands() throws {
        var cell = rectangle(length: 1)
        cell.pins[0].position = .init(x: 0.5, y: 0.5); cell.pins[0].size = .init(width: 0.5, height: 1)
        let source = try network(cell)
        #expect(throws: NativePEXElectrodeError.uncoveredFace(pinIndex: 0, faceIndex: 0)) {
            try build(source, [binding(0, side: .minX, coordinate: 0), binding(1, side: .maxX, coordinate: 2000)])
        }
    }

    @Test func overlappingElectrodesCannotDoubleTheBoundaryConductance() throws {
        let source = try network(rectangle(length: 1))
        let a = binding(0, side: .minX, coordinate: 0)
        #expect(throws: NativePEXElectrodeError.overlappingElectrodes(firstPinIndex: 0, secondPinIndex: 0)) {
            try build(source, [.init(pinIndex: 0, terminal: a.terminal, faces: a.faces + a.faces), binding(1, side: .maxX, coordinate: 2000)])
        }
        #expect(throws: NativePEXElectrodeError.overlappingElectrodes(firstPinIndex: 0, secondPinIndex: 1)) {
            try build(source, [a, binding(1, side: .minX, coordinate: 0)])
        }
    }

    @Test func deterministicBindingsAndResourceAdmission() throws {
        let source = try network(rectangle(length: 1))
        let bindings = [binding(0, side: .minX, coordinate: 0), binding(1, side: .maxX, coordinate: 2000)]
        let a = try build(source, bindings), b = try build(source, bindings.reversed())
        #expect(a.ports == b.ports && a.contacts == b.contacts)
        for (limits, error) in [(NativePEXElectrodeLimits(maximumInputRecords: 0), NativePEXElectrodeError.limitExceeded(.inputRecords)),
            (.init(maximumFaceRecords: 0), .limitExceeded(.faceRecords)),
            (.init(maximumContacts: 0), .limitExceeded(.contacts)),
            (.init(maximumWorkVisits: 0), .limitExceeded(.workVisits)),
            (.init(maximumContacts: -1), .invalidConfiguration)] {
            #expect(throws: error) { try build(source, bindings, limits: limits) }
        }
        #expect(try build(source, bindings, limits: .init(maximumContacts: 2)).contacts.count == 2)
        let data = try JSONEncoder().encode(bindings)
        #expect(try JSONDecoder().decode([NativePEXElectrodeBinding].self, from: data) == bindings)
    }

    @Test func cancellationAfterConstructionStartsPublishesNothing() throws {
        let source = try network(rectangle(), span: 500), builder = RectilinearPEXElectrodeBuilder()
        var checks = 0, output: NativePEXElectrodeNetwork?
        #expect(throws: NativePEXElectrodeError.cancelled) {
            output = try builder.build(network: source, bindings: [binding(0, side: .minX, coordinate: 0), binding(1, side: .maxX, coordinate: 6000)], isCancelled: {
                checks += 1; return checks == 70
            })
        }
        #expect(output == nil && checks == 70)
    }

    @Test func identifierBytesAreAdmittedBeforeValidationAndHashing() throws {
        let source = try network(rectangle(length: 1)), builder = RectilinearPEXElectrodeBuilder()
        let b = binding(1, side: .maxX, coordinate: 2000)
        for name in [String(repeating: "N", count: 1024), String(repeating: " ", count: 1024),
                     String(repeating: "\u{301}", count: 1024)] {
            let a = NativePEXElectrodeBinding(pinIndex: 0,
                terminal: .init(netName: NetName(name), nodeName: NodeName("A")),
                faces: binding(0, side: .minX, coordinate: 0).faces)
            var output: NativePEXElectrodeNetwork?
            #expect(throws: NativePEXElectrodeError.limitExceeded(.inputRecords)) {
                output = try build(source, [a, b], limits: .init(maximumInputRecords: 32))
            }
            #expect(output == nil)
            var checks = 0
            #expect(throws: NativePEXElectrodeError.cancelled) {
                output = try builder.build(network: source, bindings: [a, b], isCancelled: {
                    checks += 1; return checks == 16
                })
            }
            #expect(output == nil && checks == 16)
        }
    }

    @Test func invalidIntervalsAndLateContactLimitPublishNothing() throws {
        let source = try network(rectangle(length: 1)), builder = RectilinearPEXElectrodeBuilder()
        let a = binding(0, side: .minX, coordinate: 0), b = binding(1, side: .maxX, coordinate: 2000)
        for end: Int32 in [0, -2] {
            #expect(throws: NativePEXElectrodeError.invalidFace(pinIndex: 0, faceIndex: 0)) {
                try build(source, [binding(0, side: .minX, coordinate: 0, end: end), b])
            }
        }
        var output: NativePEXElectrodeNetwork?
        #expect(throws: NativePEXElectrodeError.limitExceeded(.contacts)) {
            output = try builder.build(network: source, bindings: [a, b], limits: .init(maximumContacts: 1))
        }
        #expect(output == nil && source.nodes.count == 1 && source.resistors.isEmpty)
    }

    @Test func unrepresentablePositiveContactResistanceFailsInsteadOfShorting() throws {
        let original = try fixture.technology(), model = try original.electricalModel(for: PEXCorner(id: "tt"))
        let range = PEXDimensionRangeMeters(minimumMeters: 1e-12, maximumMeters: 10)
        let conductors = model.conductors.map { layer in
            PEXConductorElectricalModel(layerName: layer.layerName,
                bottomHeightMeters: layer.layerName == "M1" ? 0 : 2,
                thicknessMeters: layer.layerName == "M1" ? 1 : layer.thicknessMeters,
                resistivityOhmMeters: layer.layerName == "M1" ? Double.leastNonzeroMagnitude : layer.resistivityOhmMeters,
                groundAreaFaradsPerSquareMeter: 0, groundPerimeterFaradsPerMeter: 0,
                widthRange: range, lengthRange: range)
        }
        let tiny = PEXElectricalModel(law: model.law, coplanarScreening: nil, processName: model.processName, cornerID: model.cornerID,
            temperatureKelvin: model.temperatureKelvin, voltageVolts: model.voltageVolts, parameters: model.parameters,
            referenceNodeName: model.referenceNodeName, calibrationArtifacts: model.calibrationArtifacts,
            conductors: conductors, vias: model.vias, couplings: model.couplings)
        let technology = TechnologyIR(processName: original.processName, stack: original.stack,
            logicalToPhysicalLayerMap: original.logicalToPhysicalLayerMap, vias: original.vias,
            defaultExtractionRules: original.defaultExtractionRules, backendHints: original.backendHints, electricalModels: [tiny])
        let source = try network(rectangle(length: 0.001, width: 1_000_000), span: Int32.max, technology: technology)
        #expect(source.nodes.count == 1 && source.resistors.isEmpty)
        var output: NativePEXElectrodeNetwork?
        #expect(throws: NativePEXElectrodeError.numericFailure) {
            output = try build(source, [binding(0, side: .minX, coordinate: 0, end: 2_000_000_000),
                binding(1, side: .maxX, coordinate: 2, end: 2_000_000_000)])
        }
        #expect(output == nil)
    }

    // This bounded dense Kirchhoff reference is independent of the production face builder.
    private func resistance(_ graph: NativePEXElectrodeNetwork) throws -> Double {
        let n = graph.network.nodes.count
        try #require(n > 0 && n <= 512 && graph.ports.count == 2)
        var matrix = [Double](repeating: 0, count: n * n), rhs = [Double](repeating: 0, count: n)
        for edge in graph.network.resistors {
            let conductance = 1 / edge.ohms, a = edge.nodeA, b = edge.nodeB
            matrix[a * n + a] += conductance; matrix[b * n + b] += conductance
            matrix[a * n + b] -= conductance; matrix[b * n + a] -= conductance
        }
        for edge in graph.contacts {
            let conductance = 1 / edge.ohms
            matrix[edge.nodeIndex * n + edge.nodeIndex] += conductance
            if edge.portIndex == 0 { rhs[edge.nodeIndex] += conductance }
        }
        for column in 0..<n {
            let pivot = try #require((column..<n).max { abs(matrix[$0 * n + column]) < abs(matrix[$1 * n + column]) })
            try #require(matrix[pivot * n + column].isFinite && matrix[pivot * n + column] != 0)
            if pivot != column {
                for j in 0..<n { matrix.swapAt(column * n + j, pivot * n + j) }
                rhs.swapAt(column, pivot)
            }
            let value = matrix[column * n + column]
            for j in column..<n { matrix[column * n + j] /= value }; rhs[column] /= value
            for row in (column + 1)..<n {
                let multiplier = matrix[row * n + column]
                for j in column..<n { matrix[row * n + j] -= multiplier * matrix[column * n + j] }
                rhs[row] -= multiplier * rhs[column]
            }
        }
        var potential = [Double](repeating: 0, count: n)
        for row in (0..<n).reversed() {
            var value = rhs[row]
            for column in (row + 1)..<n { value -= matrix[row * n + column] * potential[column] }
            potential[row] = value
        }
        let current = graph.contacts.filter { $0.portIndex == 0 }.reduce(0.0) { $0 + (1 - potential[$1.nodeIndex]) / $1.ohms }
        try #require(current.isFinite && current > 0)
        return 1 / current
    }
}
