import Foundation
import Testing
@testable import PEXCLICore
@testable import PEXCore

@Suite("Write SPEF command")
struct WriteSPEFCommandTests {
    @Test func arguments() throws {
        let cmd = try WriteSPEFCommand(arguments: [
            "--input",
            "/tmp/ir.json",
            "--output",
            "/tmp/out.spef",
            "--design-name",
            "top",
            "--date",
            "2026-06-30",
            "--vendor",
            "LSI",
            "--program",
            "pexengine",
            "--report",
            "/tmp/write-report.json",
            "--round-trip",
            "--round-trip-corner",
            "ff",
            "--json",
        ])

        #expect(cmd.inputPath == "/tmp/ir.json")
        #expect(cmd.outputPath == "/tmp/out.spef")
        #expect(cmd.designName == "top")
        #expect(cmd.date == "2026-06-30")
        #expect(cmd.vendor == "LSI")
        #expect(cmd.program == "pexengine")
        #expect(cmd.reportPath == "/tmp/write-report.json")
        #expect(cmd.roundTrip)
        #expect(cmd.roundTripCornerID == "ff")
        #expect(cmd.jsonOutput)
    }

    @Test func writesParseableSPEFFromRetainedIR() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pex-write-spef-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeTemporaryItem(directory) }

        let inputURL = directory.appending(path: "ir.json")
        let outputURL = directory.appending(path: "out.spef")
        let reportURL = directory.appending(path: "reports/write-spef.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(makeWriteSPEFIR()).write(to: inputURL, options: .atomic)

        let report = try WriteSPEFCommand(arguments: [
            "--input",
            inputURL.path,
            "--output",
            outputURL.path,
            "--report",
            reportURL.path,
            "--round-trip",
            "--design-name",
            "cli_top",
            "--json",
        ]).write()

        #expect(report.status == "passed")
        #expect(report.inputPath == inputURL.path)
        #expect(report.inputSHA256.count == 64)
        #expect(report.inputByteCount > 0)
        #expect(report.outputPath == outputURL.path)
        #expect(report.outputSHA256.count == 64)
        #expect(report.outputByteCount > 0)
        #expect(report.reportPath == reportURL.path)
        #expect(report.netCount == 1)
        #expect(report.nodeCount == 2)
        #expect(report.elementCount == 2)
        #expect(report.roundTrip?.status == "passed")
        #expect(report.roundTrip?.cornerID == "tt")
        #expect(report.roundTrip?.netCount == 1)
        #expect(report.roundTrip?.nodeCount == 2)
        #expect(report.roundTrip?.elementCount == 2)
        #expect(report.roundTrip?.semanticStatus == "passed")
        #expect(report.roundTrip?.semanticViolationCount == 0)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        #expect(FileManager.default.fileExists(atPath: reportURL.path))

        let savedReport = try JSONDecoder().decode(SPEFWriteReport.self, from: Data(contentsOf: reportURL))
        #expect(savedReport == report)

        let spef = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(spef.contains("*NAME_MAP"))
        #expect(spef.contains("m1_0_0#"))

        let parseReport = try ParseCommand(arguments: [
            "--input",
            outputURL.path,
            "--format",
            "spef",
            "--corner",
            "tt",
            "--report",
        ]).buildReport()

        #expect(parseReport.status == "passed")
        #expect(parseReport.summary.netCount == 1)
        #expect(parseReport.summary.nodeCount == 2)
        #expect(parseReport.summary.elementCount == 2)
        #expect(parseReport.summary.inductorCount == 0)
        #expect(parseReport.summary.totalInductanceH == 0)
        #expect(parseReport.validation.errorCount == 0)
    }

    @Test func rejectsMissingOutput() {
        expectInvalidInput(
            arguments: ["--input", "/tmp/ir.json"],
            contains: "--output"
        )
    }

    @Test func rejectsOptionTokenAsOptionValue() {
        expectInvalidInput(
            arguments: ["--input", "--output", "/tmp/out.spef"],
            contains: "--input requires a value"
        )
    }

    @Test func rejectsUnexpectedPositionalArgument() {
        expectInvalidInput(
            arguments: ["/tmp/ir.json", "/tmp/out.spef", "/tmp/extra.spef"],
            contains: "Unexpected write-spef positional argument"
        )
    }

    private func expectInvalidInput(arguments: [String], contains expectedMessage: String) {
        do {
            _ = try WriteSPEFCommand(arguments: arguments)
            #expect(Bool(false), "Expected invalid input to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains(expectedMessage))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    private func makeWriteSPEFIR() -> ParasiticIR {
        let net = NetName("OUT")
        let firstNode = NodeName("m1_0_0#")
        let secondNode = NodeName("m1_1_0#")
        return ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: [
                ParasiticNet(
                    name: net,
                    nodes: [
                        ParasiticNode(name: firstNode, kind: .internal, instancePath: nil, coordinate: Point2D(x: 1, y: 2)),
                        ParasiticNode(name: secondNode, kind: .internal, instancePath: nil, coordinate: Point2D(x: 3, y: 4)),
                    ],
                    totalGroundCapF: 1e-15,
                    totalCouplingCapF: 0,
                    totalResistanceOhm: 5
                ),
            ],
            elements: [
                ParasiticElement(
                    id: "Cphys",
                    kind: .capacitor,
                    nodeA: NodeRef(netName: net, nodeName: firstNode),
                    nodeB: nil,
                    value: 1e-15,
                    source: .extracted
                ),
                ParasiticElement(
                    id: "Rphys",
                    kind: .resistor,
                    nodeA: NodeRef(netName: net, nodeName: firstNode),
                    nodeB: NodeRef(netName: net, nodeName: secondNode),
                    value: 5,
                    source: .extracted
                ),
            ],
            metadata: ["designName": "cli_top"]
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
