import Foundation
import Testing
@testable import PEXCLICore
@testable import PEXCore
@testable import PEXEngine

@Suite("PEXCLI diagnostic command tests")
struct PEXCLIDiagnosticCommandTests {
    @Test func doctorCommandJson() throws {
        let cmd = try DoctorCommand(arguments: ["--json"])
        #expect(cmd.jsonOutput == true)
    }

    @Test func doctorCommandDefault() throws {
        let cmd = try DoctorCommand(arguments: [])
        #expect(cmd.jsonOutput == false)
    }

    @Test func doctorCommandRejectsUnknownArgument() throws {
        #expect(throws: PEXError.self) {
            _ = try DoctorCommand(arguments: ["--unexpected"])
        }
    }

    @Test func doctorReportJSONRoundTripIncludesBackendReadiness() throws {
        let report = try DoctorCommand(arguments: ["--json"]).buildReport()
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: data)

        #expect(decoded.checks.contains { $0.name == "Parser Registration" && $0.status == .ok })
        #expect(decoded.checks.contains { $0.name == "Backend Registration" && $0.status == .ok })
        #expect(decoded.checks.contains { $0.name == "Temp Directory" })

        let magic = try #require(decoded.backends.first { $0.id == "magic" })
        #expect(magic.readiness.backendID == "magic")
        #expect([PEXExtractorReadinessStatus.ready, .blocked].contains(magic.readiness.status))
        #expect(!magic.readiness.reason.isEmpty)
        #expect(magic.readiness.capabilities != nil)
        if magic.readiness.status == .blocked {
            #expect(magic.readiness.diagnostics.contains {
                $0.code == "extractor_toolchain_missing" && $0.severity == .blocked
            })
            #expect(!magic.readiness.suggestedActions.isEmpty)
        }
    }

    @Test func doctorReportUsesDefaultParserRegistry() throws {
        let report = try DoctorCommand(arguments: ["--json"]).buildReport()
        let parserCheck = try #require(report.checks.first { $0.name == "Parser Registration" })
        let defaultFormats = PEXDefaultParsers.makeAll().map(\.format.rawValue)

        #expect(parserCheck.status == .ok)
        for format in defaultFormats {
            #expect(parserCheck.detail.contains(format))
        }
    }

    @Test func listBackendsCommandJson() throws {
        let cmd = try ListBackendsCommand(arguments: ["--json"])
        #expect(cmd.jsonOutput == true)
    }

    @Test func listBackendsCommandDefault() throws {
        let cmd = try ListBackendsCommand(arguments: [])
        #expect(cmd.jsonOutput == false)
    }

    @Test func listBackendsCommandRejectsUnknownArgument() throws {
        #expect(throws: PEXError.self) {
            _ = try ListBackendsCommand(arguments: ["--unexpected"])
        }
    }

    @Test func listBackendsEntriesJSONRoundTripIncludesReadiness() throws {
        let entries = try ListBackendsCommand(arguments: ["--json"]).buildEntries()
        let data = try JSONEncoder().encode(entries)
        let decoded = try JSONDecoder().decode([BackendEntry].self, from: data)

        #expect(Set(decoded.map(\.id)) == Set(["magic"]))
        for entry in decoded {
            #expect(entry.readiness.backendID == entry.id)
            #expect(!entry.readiness.reason.isEmpty)
            #expect(entry.readiness.capabilities != nil)
        }

        let magic = try #require(decoded.first { $0.id == "magic" })
        #expect([PEXExtractorReadinessStatus.ready, .blocked].contains(magic.readiness.status))
        #expect(magic.nativeOutputFormats.contains("spice"))
    }

    @Test func exitCodeMapping() {
        #expect(CLIRouter.exitCode(for: .invalidInput) == 1)
        #expect(CLIRouter.exitCode(for: .technologyResolutionFailed) == 2)
        #expect(CLIRouter.exitCode(for: .adapterUnavailable) == 1)
        #expect(CLIRouter.exitCode(for: .backendExecutionFailed) == 3)
        #expect(CLIRouter.exitCode(for: .parseFailed) == 4)
        #expect(CLIRouter.exitCode(for: .irValidationFailed) == 4)
        #expect(CLIRouter.exitCode(for: .persistenceFailed) == 5)
        #expect(CLIRouter.exitCode(for: .internalInvariantViolation) == 5)
    }
}
