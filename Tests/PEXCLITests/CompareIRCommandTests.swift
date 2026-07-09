import Foundation
import Testing
@testable import PEXCLICore
@testable import PEXCore

@Suite("Compare IR command")
struct CompareIRCommandTests {
    @Test func arguments() throws {
        let command = try CompareIRCommand(arguments: [
            "--baseline",
            "/tmp/base.json",
            "--candidate",
            "/tmp/candidate.json",
            "--report",
            "/tmp/compare.json",
            "--cap-abs-tolerance-f",
            "1e-15",
            "--cap-rel-tolerance",
            "0.1",
            "--res-abs-tolerance-ohm",
            "2",
            "--res-rel-tolerance",
            "0.25",
            "--value-abs-tolerance",
            "1e-21",
            "--allow-net-set-changes",
            "--equivalence",
            "--json",
        ])

        #expect(command.baselinePath == "/tmp/base.json")
        #expect(command.candidatePath == "/tmp/candidate.json")
        #expect(command.reportPath == "/tmp/compare.json")
        #expect(command.thresholds.maxCapDeltaF == 1e-15)
        #expect(command.thresholds.maxCapRelativeDelta == 0.1)
        #expect(command.thresholds.maxResistanceDeltaOhm == 2)
        #expect(command.thresholds.maxResistanceRelativeDelta == 0.25)
        #expect(command.thresholds.equivalenceValueTolerance == 1e-21)
        #expect(command.thresholds.allowNetSetChanges)
        #expect(command.equivalenceMode)
        #expect(command.jsonOutput)
    }

    @Test func comparesIRAndWritesRegressionReport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pex-compare-ir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeTemporaryItem(directory) }

        let baselineURL = directory.appending(path: "baseline.json")
        let candidateURL = directory.appending(path: "candidate.json")
        let reportURL = directory.appending(path: "reports/compare.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(makeIR(capF: 1e-15, resistanceOhm: 5)).write(to: baselineURL, options: .atomic)
        try encoder.encode(makeIR(capF: 1.8e-15, resistanceOhm: 8)).write(to: candidateURL, options: .atomic)

        let report = try CompareIRCommand(arguments: [
            "--baseline",
            baselineURL.path,
            "--candidate",
            candidateURL.path,
            "--report",
            reportURL.path,
            "--cap-abs-tolerance-f",
            "5e-16",
            "--cap-rel-tolerance",
            "0.5",
            "--res-abs-tolerance-ohm",
            "2",
            "--res-rel-tolerance",
            "0.5",
        ]).compare()

        #expect(report.status == "failed")
        #expect(report.baseline.path == baselineURL.path)
        #expect(report.baseline.sha256.count == 64)
        #expect(report.baseline.byteCount > 0)
        #expect(report.candidate.path == candidateURL.path)
        #expect(report.candidate.sha256.count == 64)
        #expect(report.summary.matchedNetCount == 1)
        #expect(report.summary.addedNetCount == 0)
        #expect(report.summary.removedNetCount == 0)
        #expect(report.summary.changedNetCount == 1)
        #expect(report.summary.violationCount == 4)
        #expect(report.summary.totalCapDeltaF == 8e-16)
        #expect(report.summary.totalResistanceDeltaOhm == 3)
        #expect(report.summary.worstCapDeltaNet == "OUT")
        #expect(report.summary.worstResistanceDeltaNet == "OUT")
        #expect(report.violations.map(\.kind) == [
            "capacitance_absolute_regression",
            "capacitance_relative_regression",
            "resistance_absolute_regression",
            "resistance_relative_regression",
        ])

        let diff = try #require(report.netDiffs.first)
        #expect(diff.netName == "OUT")
        #expect(diff.status == "changed")
        #expect(diff.deltaTotalCapF == 8e-16)
        #expect(diff.deltaResistanceOhm == 3)
        #expect(abs((diff.relativeTotalCapDelta ?? 0) - 0.8) < 1e-12)
        #expect(abs((diff.relativeResistanceDelta ?? 0) - 0.6) < 1e-12)

        let savedReport = try JSONDecoder().decode(PEXIRComparisonReport.self, from: Data(contentsOf: reportURL))
        #expect(savedReport == report)
    }

    @Test func equivalenceModeFailsOnSemanticDriftInEitherDirection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pex-compare-ir-equivalence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeTemporaryItem(directory) }

        let baselineURL = directory.appending(path: "baseline.json")
        let candidateURL = directory.appending(path: "candidate.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(makeIR(capF: 1e-15, resistanceOhm: 5)).write(to: baselineURL, options: .atomic)
        try encoder.encode(makeIR(capF: 0.6e-15, resistanceOhm: 5)).write(to: candidateURL, options: .atomic)

        let regressionReport = try CompareIRCommand(arguments: [
            "--baseline",
            baselineURL.path,
            "--candidate",
            candidateURL.path,
            "--cap-abs-tolerance-f",
            "1e-18",
        ]).compare()
        #expect(regressionReport.status == "passed")
        #expect(regressionReport.comparisonMode == "regression")

        let equivalenceReport = try CompareIRCommand(arguments: [
            "--baseline",
            baselineURL.path,
            "--candidate",
            candidateURL.path,
            "--equivalence",
            "--value-abs-tolerance",
            "1e-21",
        ]).compare()
        #expect(equivalenceReport.status == "failed")
        #expect(equivalenceReport.comparisonMode == "equivalence")
        #expect(equivalenceReport.violations.contains { $0.kind == "ground_capacitance_mismatch" })
        #expect(equivalenceReport.violations.contains { $0.kind == "element_value_mismatch" })
    }

    @Test func equivalenceModeFailsOnCoordinateDrift() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pex-compare-ir-coordinate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeTemporaryItem(directory) }

        let baselineURL = directory.appending(path: "baseline.json")
        let candidateURL = directory.appending(path: "candidate.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(makeIR(
            capF: 1e-15,
            resistanceOhm: 5,
            firstCoordinate: Point2D(x: 1, y: 2)
        )).write(to: baselineURL, options: .atomic)
        try encoder.encode(makeIR(
            capF: 1e-15,
            resistanceOhm: 5,
            firstCoordinate: nil
        )).write(to: candidateURL, options: .atomic)

        let report = try CompareIRCommand(arguments: [
            "--baseline",
            baselineURL.path,
            "--candidate",
            candidateURL.path,
            "--equivalence",
        ]).compare()

        #expect(report.status == "failed")
        #expect(report.violations.contains { $0.kind == "node_coordinate_mismatch" })
    }

    @Test func netSetChangesFailUnlessExplicitlyAllowed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pex-compare-ir-nets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeTemporaryItem(directory) }

        let baselineURL = directory.appending(path: "baseline.json")
        let candidateURL = directory.appending(path: "candidate.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(makeIR(netName: "OUT", capF: 1e-15, resistanceOhm: 5)).write(to: baselineURL, options: .atomic)
        try encoder.encode(makeIR(netName: "ALT", capF: 1e-15, resistanceOhm: 5)).write(to: candidateURL, options: .atomic)

        let strictReport = try CompareIRCommand(arguments: [
            "--baseline",
            baselineURL.path,
            "--candidate",
            candidateURL.path,
        ]).compare()

        #expect(strictReport.status == "failed")
        #expect(strictReport.summary.addedNetCount == 1)
        #expect(strictReport.summary.removedNetCount == 1)
        #expect(strictReport.violations.map(\.kind) == ["net_added", "net_removed"])

        let allowedReport = try CompareIRCommand(arguments: [
            "--baseline",
            baselineURL.path,
            "--candidate",
            candidateURL.path,
            "--allow-net-set-changes",
        ]).compare()

        #expect(allowedReport.status == "passed")
        #expect(allowedReport.summary.addedNetCount == 1)
        #expect(allowedReport.summary.removedNetCount == 1)
        #expect(allowedReport.violations.isEmpty)
    }

    @Test func rejectsMissingCandidate() {
        expectInvalidInput(
            arguments: ["--baseline", "/tmp/base.json"],
            contains: "--candidate"
        )
    }

    @Test func rejectsOptionTokenAsOptionValue() {
        expectInvalidInput(
            arguments: ["--baseline", "--candidate", "/tmp/candidate.json"],
            contains: "--baseline requires a value"
        )
        expectInvalidInput(
            arguments: ["--baseline", "/tmp/base.json", "--candidate", "--report"],
            contains: "--candidate requires a value"
        )
        expectInvalidInput(
            arguments: ["/tmp/base.json", "/tmp/candidate.json", "--report", "--json"],
            contains: "--report requires a value"
        )
        expectInvalidInput(
            arguments: ["/tmp/base.json", "/tmp/candidate.json", "--cap-abs-tolerance-f", "--json"],
            contains: "--cap-abs-tolerance-f requires a value"
        )
    }

    @Test func rejectsInvalidNumericTolerance() {
        expectInvalidInput(
            arguments: ["/tmp/base.json", "/tmp/candidate.json", "--res-rel-tolerance", "-0.1"],
            contains: "--res-rel-tolerance requires a value"
        )
        expectInvalidInput(
            arguments: ["/tmp/base.json", "/tmp/candidate.json", "--value-abs-tolerance", "nan"],
            contains: "--value-abs-tolerance requires a non-negative numeric value"
        )
    }

    private func expectInvalidInput(arguments: [String], contains expectedMessage: String) {
        do {
            _ = try CompareIRCommand(arguments: arguments)
            #expect(Bool(false), "Expected invalid compare-ir arguments to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains(expectedMessage))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    private func makeIR(
        netName: String = "OUT",
        capF: Double,
        resistanceOhm: Double,
        firstCoordinate: Point2D? = nil,
        secondCoordinate: Point2D? = nil
    ) -> ParasiticIR {
        let net = NetName(netName)
        let firstNode = NodeName("\(netName)_1")
        let secondNode = NodeName("\(netName)_2")
        return ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: [
                ParasiticNet(
                    name: net,
                    nodes: [
                        ParasiticNode(name: firstNode, kind: .internal, instancePath: nil, coordinate: firstCoordinate),
                        ParasiticNode(name: secondNode, kind: .internal, instancePath: nil, coordinate: secondCoordinate),
                    ],
                    totalGroundCapF: capF,
                    totalCouplingCapF: 0,
                    totalResistanceOhm: resistanceOhm
                ),
            ],
            elements: [
                ParasiticElement(
                    id: "\(netName)_C",
                    kind: .capacitor,
                    nodeA: NodeRef(netName: net, nodeName: firstNode),
                    nodeB: nil,
                    value: capF,
                    source: .extracted
                ),
                ParasiticElement(
                    id: "\(netName)_R",
                    kind: .resistor,
                    nodeA: NodeRef(netName: net, nodeName: firstNode),
                    nodeB: NodeRef(netName: net, nodeName: secondNode),
                    value: resistanceOhm,
                    source: .extracted
                ),
            ],
            metadata: [:]
        )
    }

    private func removeTemporaryItem(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
        }
    }
}
