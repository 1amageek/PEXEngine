import Testing
import Foundation
@testable import PEXCLICore
@testable import PEXCore

@Suite("PEX ParseCommand Tests")
struct PEXParseCommandTests {
    private static let sampleSPEF = """
    *SPEF "IEEE 1481-1998"
    *DESIGN "top"
    *DATE "2024-01-01"
    *VENDOR "Test"
    *PROGRAM "Test"
    *VERSION "1.0"
    *DESIGN_FLOW "EXTERNAL"
    *DIVIDER /
    *DELIMITER :
    *BUS_DELIMITER [ ]
    *T_UNIT 1 NS
    *C_UNIT 1 PF
    *R_UNIT 1 OHM
    *L_UNIT 1 HENRY

    *NAME_MAP
    *1 VDD
    *2 VSS

    *PORTS
    VDD I
    VSS O

    *D_NET VDD 0.150000
    *CONN
    *I top:VDD I
    *CAP
    1 VDD:1 0.100000
    2 VDD:1 VDD:2 0.050000
    *RES
    1 VDD:1 VDD:2 10.0000
    *END

    *D_NET VSS 0.080000
    *CONN
    *I top:VSS O
    *CAP
    1 VSS:1 0.080000
    *RES
    1 VSS:1 VSS:2 5.0000
    *END
    """

    @Test func parseCommandArguments() throws {
        let cmd = try ParseCommand(arguments: ["--input", "/tmp/test.spef", "--format", "spef", "--corner", "tt", "--json", "--report"])
        #expect(cmd.inputPath == "/tmp/test.spef")
        #expect(cmd.format == .spef)
        #expect(cmd.cornerID == "tt")
        #expect(cmd.jsonOutput == true)
        #expect(cmd.reportOutput == true)
    }

    @Test func parseCommandDefaults() throws {
        let cmd = try ParseCommand(arguments: ["/tmp/test.spef"])
        #expect(cmd.inputPath == "/tmp/test.spef")
        #expect(cmd.format == .spef)
        #expect(cmd.cornerID == "default")
        #expect(cmd.jsonOutput == false)
    }

    @Test func parseCommandAcceptsDSPFAndSPICEFormats() throws {
        let dspf = try ParseCommand(arguments: ["--input", "/tmp/test.dspf", "--format", "dspf", "--top-subckt", "top"])
        let spice = try ParseCommand(arguments: ["--input", "/tmp/test.spice", "--format", "spice"])

        #expect(dspf.format == .dspf)
        #expect(dspf.topSubckt == "top")
        #expect(spice.format == .spice)
        #expect(spice.topSubckt == nil)
    }

    @Test func parseCommandBuildsAgentReadableReport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pex-parse-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeParseTemporaryItem(directory) }

        let spefURL = directory.appending(path: "sample.spef")
        let spefData = try #require(Self.sampleSPEF.data(using: .utf8))
        try spefData.write(to: spefURL, options: .atomic)

        let report = try ParseCommand(arguments: [
            "--input",
            spefURL.path,
            "--format",
            "spef",
            "--corner",
            "tt",
            "--report",
        ]).buildReport()

        #expect(report.schemaVersion == 1)
        #expect(report.inputPath == spefURL.path)
        #expect(report.format == .spef)
        #expect(report.cornerID == "tt")
        #expect(report.summary.netCount == 2)
        #expect(report.summary.elementCount == 5)
        #expect(report.summary.capacitorCount == 3)
        #expect(report.summary.resistorCount == 2)
        #expect(report.summary.inductorCount == 0)
        #expect(report.summary.totalInductanceH == 0)
        #expect(report.summary.topNetsByCapacitance.first?.name == "VDD")
        #expect(report.validation.errorCount == report.validation.diagnostics.filter { $0.severity == "error" }.count)
    }

    @Test func parseCommandReportsSPEFInductors() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pex-parse-inductor-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeParseTemporaryItem(directory) }

        let spefURL = directory.appending(path: "inductor.spef")
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "inductor"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM
        *L_UNIT 1 NH

        *D_NET OUT 0.0
        *CONN
        *I OUT:1 I
        *INDUC
        1 OUT:1 OUT:2 3.0
        *END
        """
        try Data(spef.utf8).write(to: spefURL)

        let report = try ParseCommand(arguments: [
            "--input",
            spefURL.path,
            "--format",
            "spef",
            "--corner",
            "tt",
            "--report",
        ]).buildReport()

        #expect(report.status == "passed")
        #expect(report.summary.elementCount == 1)
        #expect(report.summary.inductorCount == 1)
        #expect(abs(report.summary.totalInductanceH - 3e-9) < 1e-18)
        #expect(report.validation.errorCount == 0)
    }

    @Test func parseCommandReportsDSPFInductors() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pex-parse-dspf-inductor-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeParseTemporaryItem(directory) }

        let dspfURL = directory.appending(path: "inductor.dspf")
        let dspf = """
        .subckt top OUT
        Lseg OUT:1 OUT:2 4n
        .ends top
        """
        try Data(dspf.utf8).write(to: dspfURL)

        let report = try ParseCommand(arguments: [
            "--input",
            dspfURL.path,
            "--format",
            "dspf",
            "--corner",
            "tt",
            "--report",
        ]).buildReport()

        #expect(report.status == "passed")
        #expect(report.summary.elementCount == 1)
        #expect(report.summary.inductorCount == 1)
        #expect(abs(report.summary.totalInductanceH - 4e-9) < 1e-18)
        #expect(report.validation.errorCount == 0)
    }

    @Test func parseCommandReportsSPICEInductors() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pex-parse-spice-inductor-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeParseTemporaryItem(directory) }

        let spiceURL = directory.appending(path: "inductor.spice")
        let spice = """
        Lseg OUT:1 OUT:2 5n
        """
        try Data(spice.utf8).write(to: spiceURL)

        let report = try ParseCommand(arguments: [
            "--input",
            spiceURL.path,
            "--format",
            "spice",
            "--corner",
            "tt",
            "--report",
        ]).buildReport()

        #expect(report.status == "passed")
        #expect(report.summary.elementCount == 1)
        #expect(report.summary.inductorCount == 1)
        #expect(abs(report.summary.totalInductanceH - 5e-9) < 1e-18)
        #expect(report.validation.errorCount == 0)
    }

    @Test func parseCommandRejectsUnknownFormat() {
        expectInvalidInput(
            arguments: ["--input", "/tmp/test.unknown", "--format", "unknown"],
            contains: "Unsupported format"
        )
    }

    @Test func parseCommandMissingInput() {
        expectInvalidInput(arguments: [], contains: "Input file path")
    }

    @Test func parseCommandRejectsUnknownArgumentAfterInput() {
        expectInvalidInput(
            arguments: ["--input", "/tmp/test.spef", "--unexpected"],
            contains: "--unexpected"
        )
    }

    @Test func parseCommandRejectsUnexpectedPositionalArgumentAfterInput() {
        expectInvalidInput(
            arguments: ["/tmp/test.spef", "/tmp/extra.spef"],
            contains: "/tmp/extra.spef"
        )
    }

    @Test func parseCommandRejectsOptionTokenAsOptionValue() {
        expectInvalidInput(
            arguments: ["--input", "--format", "spef"],
            contains: "--input requires a value"
        )
        expectInvalidInput(
            arguments: ["--input", "/tmp/test.spef", "--format", "--corner"],
            contains: "--format requires a value"
        )
        expectInvalidInput(
            arguments: ["--input", "/tmp/test.spef", "--corner", "--json"],
            contains: "--corner requires a value"
        )
        expectInvalidInput(
            arguments: ["--input", "/tmp/test.dspf", "--format", "dspf", "--top-subckt", "--json"],
            contains: "--top-subckt requires a value"
        )
    }

    private func expectInvalidInput(arguments: [String], contains expectedMessage: String) {
        do {
            _ = try ParseCommand(arguments: arguments)
            #expect(Bool(false), "Expected invalid parse arguments to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains(expectedMessage))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }
}

private func removeParseTemporaryItem(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
    }
}
