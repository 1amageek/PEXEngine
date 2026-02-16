import Testing
import Foundation
@testable import PEXCLICore
@testable import PEXCore

@Suite("PEXCLI Tests")
struct PEXCLITests {

    // MARK: - ExtractCommand Argument Parsing

    @Test func extractCommandConfigMode() throws {
        let cmd = try ExtractCommand(arguments: ["--config", "/tmp/config.json", "--json"])
        #expect(cmd.configURL?.path(percentEncoded: false) == "/tmp/config.json")
        #expect(cmd.jsonOutput == true)
        #expect(cmd.directParams == nil)
    }

    @Test func extractCommandDirectMode() throws {
        let cmd = try ExtractCommand(arguments: [
            "--layout", "/tmp/layout.gds",
            "--netlist", "/tmp/netlist.sp",
            "--top-cell", "TOP",
            "--technology", "/tmp/tech.json",
            "--backend", "mock",
            "--corner", "tt",
            "--corner", "ss",
            "--max-jobs", "4",
            "--include-coupling",
            "--min-cap-f", "1e-15",
            "--min-res-ohm", "0.1",
            "--out", "/tmp/output",
            "--strict",
        ])
        #expect(cmd.configURL == nil)
        let params = cmd.directParams
        #expect(params != nil)
        #expect(params?.layoutPath == "/tmp/layout.gds")
        #expect(params?.netlistPath == "/tmp/netlist.sp")
        #expect(params?.topCell == "TOP")
        #expect(params?.technologyPath == "/tmp/tech.json")
        #expect(params?.backendID == "mock")
        #expect(params?.corners == ["tt", "ss"])
        #expect(params?.maxJobs == 4)
        #expect(params?.includeCoupling == true)
        #expect(params?.minCapF == 1e-15)
        #expect(params?.minResOhm == 0.1)
        #expect(params?.outputPath == "/tmp/output")
        #expect(params?.strict == true)
    }

    @Test func extractCommandDefaultCorner() throws {
        let cmd = try ExtractCommand(arguments: [
            "--layout", "/tmp/l.gds",
            "--netlist", "/tmp/n.sp",
            "--top-cell", "T",
            "--technology", "/tmp/t.json",
        ])
        #expect(cmd.directParams?.corners == ["tt_25c_1v0"])
        #expect(cmd.directParams?.backendID == "mock")
    }

    @Test func extractCommandPartialDirectParamsRejects() {
        do {
            _ = try ExtractCommand(arguments: ["--layout", "/tmp/l.gds", "--netlist", "/tmp/n.sp"])
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func extractCommandMissingConfigArg() {
        do {
            _ = try ExtractCommand(arguments: ["--config"])
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func extractCommandNoParams() throws {
        let cmd = try ExtractCommand(arguments: ["--json"])
        #expect(cmd.configURL == nil)
        #expect(cmd.directParams == nil)
        #expect(cmd.jsonOutput == true)
    }

    // MARK: - ExtractCommand Request Building

    @Test func buildRequestFromDirectParams() throws {
        let cmd = try ExtractCommand(arguments: [
            "--layout", "/tmp/design.oas",
            "--netlist", "/tmp/netlist.sp",
            "--top-cell", "chip",
            "--technology", "/tmp/tech.json",
            "--corner", "ff",
            "--max-jobs", "3",
            "--min-cap-f", "1e-15",
            "--min-res-ohm", "0.1",
            "--strict",
        ])
        let request = cmd.buildRequestFromDirectParams(cmd.directParams!)
        #expect(request.layoutFormat == .oas)
        #expect(request.topCell == "chip")
        #expect(request.corners.count == 1)
        #expect(request.corners[0].id == "ff")
        #expect(request.options.maxParallelJobs == 3)
        #expect(request.options.minCapacitanceF == 1e-15)
        #expect(request.options.minResistanceOhm == 0.1)
        #expect(request.options.strictValidation == true)
        #expect(request.options.emitRawArtifacts == true)
        #expect(request.options.emitIRJSON == true)
    }

    @Test func buildRequestFromConfigFileReadsThresholds() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configJSON: [String: Any] = [
            "topCell": "CHIP",
            "backendID": "mock",
            "inputs": [
                "layout": "chip.gds",
                "netlist": "chip.sp",
                "technology": "tech.json",
            ],
            "corners": ["ff_m40c_0v9"],
            "options": [
                "includeCouplingCaps": false,
                "maxParallelJobs": 4,
                "strictValidation": true,
                "minCapacitanceF": 5e-16,
                "minResistanceOhm": 0.05,
            ],
        ]
        let configURL = tmpDir.appending(path: "config.json")
        let data = try JSONSerialization.data(withJSONObject: configJSON, options: .prettyPrinted)
        try data.write(to: configURL)

        let cmd = try ExtractCommand(arguments: ["--config", configURL.path(percentEncoded: false)])
        let request = try await cmd.buildRequestFromConfigFile(configURL)

        #expect(request.topCell == "CHIP")
        #expect(request.corners.count == 1)
        #expect(request.corners[0].id == "ff_m40c_0v9")
        #expect(request.options.includeCouplingCaps == false)
        #expect(request.options.maxParallelJobs == 4)
        #expect(request.options.strictValidation == true)
        #expect(request.options.minCapacitanceF == 5e-16)
        #expect(request.options.minResistanceOhm == 0.05)
        #expect(request.options.emitRawArtifacts == true)
        #expect(request.options.emitIRJSON == true)
    }

    @Test func buildRequestFromConfigFileDefaultsThresholdsToNil() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configJSON: [String: Any] = [
            "topCell": "T",
            "inputs": [
                "layout": "a.gds",
                "netlist": "a.sp",
                "technology": "t.json",
            ],
        ]
        let configURL = tmpDir.appending(path: "config.json")
        let data = try JSONSerialization.data(withJSONObject: configJSON, options: .prettyPrinted)
        try data.write(to: configURL)

        let cmd = try ExtractCommand(arguments: ["--config", configURL.path(percentEncoded: false)])
        let request = try await cmd.buildRequestFromConfigFile(configURL)

        #expect(request.options.minCapacitanceF == nil)
        #expect(request.options.minResistanceOhm == nil)
    }

    // MARK: - ParseCommand Argument Parsing

    @Test func parseCommandArguments() throws {
        let cmd = try ParseCommand(arguments: ["--input", "/tmp/test.spef", "--format", "spef", "--corner", "tt", "--json"])
        #expect(cmd.inputPath == "/tmp/test.spef")
        #expect(cmd.format == .spef)
        #expect(cmd.cornerID == "tt")
        #expect(cmd.jsonOutput == true)
    }

    @Test func parseCommandDefaults() throws {
        let cmd = try ParseCommand(arguments: ["/tmp/test.spef"])
        #expect(cmd.inputPath == "/tmp/test.spef")
        #expect(cmd.format == .spef)
        #expect(cmd.cornerID == "default")
        #expect(cmd.jsonOutput == false)
    }

    @Test func parseCommandRejectsUnknownFormat() {
        do {
            _ = try ParseCommand(arguments: ["--input", "/tmp/test.dspf", "--format", "dspf"])
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("Unsupported format"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func parseCommandMissingInput() {
        do {
            _ = try ParseCommand(arguments: [])
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    // MARK: - ValidateTechCommand Argument Parsing

    @Test func validateTechCommandArguments() throws {
        let cmd = try ValidateTechCommand(arguments: ["--technology", "/tmp/tech.json", "--strict", "--json"])
        #expect(cmd.technologyURL.path(percentEncoded: false) == "/tmp/tech.json")
        #expect(cmd.strict == true)
        #expect(cmd.jsonOutput == true)
    }

    @Test func validateTechCommandMissingTechnology() {
        do {
            _ = try ValidateTechCommand(arguments: ["--strict"])
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    // MARK: - SummarizeCommand Argument Parsing

    @Test func summarizeCommandArguments() throws {
        let cmd = try SummarizeCommand(arguments: ["--run", "/tmp/run1", "--top-nets", "5", "--corner", "ff", "--json"])
        #expect(cmd.runPath.path(percentEncoded: false) == "/tmp/run1")
        #expect(cmd.topNets == 5)
        #expect(cmd.cornerFilter == PEXCornerID("ff"))
        #expect(cmd.jsonOutput == true)
    }

    @Test func summarizeCommandDefaults() throws {
        let cmd = try SummarizeCommand(arguments: ["--run", "/tmp/run1"])
        #expect(cmd.topNets == 10)
        #expect(cmd.cornerFilter == nil)
        #expect(cmd.jsonOutput == false)
    }

    @Test func summarizeCommandMissingRun() {
        do {
            _ = try SummarizeCommand(arguments: ["--json"])
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func summarizeCommandInvalidTopNets() {
        do {
            _ = try SummarizeCommand(arguments: ["--run", "/tmp/r", "--top-nets", "0"])
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    // MARK: - DoctorCommand Argument Parsing

    @Test func doctorCommandJson() {
        let cmd = DoctorCommand(arguments: ["--json"])
        #expect(cmd.jsonOutput == true)
    }

    @Test func doctorCommandDefault() {
        let cmd = DoctorCommand(arguments: [])
        #expect(cmd.jsonOutput == false)
    }

    // MARK: - ListBackendsCommand Argument Parsing

    @Test func listBackendsCommandJson() throws {
        let cmd = try ListBackendsCommand(arguments: ["--json"])
        #expect(cmd.jsonOutput == true)
    }

    @Test func listBackendsCommandDefault() throws {
        let cmd = try ListBackendsCommand(arguments: [])
        #expect(cmd.jsonOutput == false)
    }

    // MARK: - CLIRouter Exit Codes

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

    // MARK: - CLIOutputFormatter

    @Test func outputFormatterSuccess() {
        let result = PEXRunResult(
            runID: PEXRunID(),
            requestHash: PEXRequestHash("h"),
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            cornerResults: [
                PEXCornerResult(
                    cornerID: "tt", status: .success,
                    ir: ParasiticIR(version: "1.0", cornerID: "tt", units: .canonical, nets: [], elements: [], metadata: [:]),
                    metrics: PEXCornerMetrics(durationSeconds: 0.5, netCount: 3, elementCount: 10)
                )
            ],
            warnings: [PEXWarning(stage: .irValidation, cornerID: "tt", message: "test warn")],
            artifacts: PEXArtifactIndex(manifestURL: URL(filePath: "/tmp/m.json"), requestURL: URL(filePath: "/tmp/r.json"), cornerArtifacts: [:]),
            metrics: PEXRunMetrics(totalDurationSeconds: 0.5, cornerCount: 1, successCount: 1, failureCount: 0)
        )

        let formatter = CLIOutputFormatter()
        let output = formatter.formatResult(result)
        #expect(output.contains("PEX Extraction Complete"))
        #expect(output.contains("success"))
        #expect(output.contains("[OK]"))
        #expect(output.contains("3 nets"))
        #expect(output.contains("10 elements"))
        #expect(output.contains("Warnings"))
        #expect(output.contains("test warn"))
    }

    @Test func outputFormatterPartialSuccess() {
        let result = PEXRunResult(
            runID: PEXRunID(),
            requestHash: PEXRequestHash("h"),
            status: .partialSuccess,
            startedAt: Date(),
            finishedAt: Date(),
            cornerResults: [
                PEXCornerResult(
                    cornerID: "tt", status: .success,
                    ir: ParasiticIR(version: "1.0", cornerID: "tt", units: .canonical, nets: [], elements: [], metadata: [:]),
                    metrics: PEXCornerMetrics(durationSeconds: 0.3, netCount: 2, elementCount: 5)
                ),
                PEXCornerResult(
                    cornerID: "ss", status: .failed,
                    ir: nil,
                    metrics: PEXCornerMetrics(durationSeconds: 0.1, netCount: 0, elementCount: 0)
                ),
            ],
            warnings: [],
            artifacts: PEXArtifactIndex(manifestURL: URL(filePath: "/tmp/m.json"), requestURL: URL(filePath: "/tmp/r.json"), cornerArtifacts: [:]),
            metrics: PEXRunMetrics(totalDurationSeconds: 0.4, cornerCount: 2, successCount: 1, failureCount: 1)
        )

        let formatter = CLIOutputFormatter()
        let output = formatter.formatResult(result)
        #expect(output.contains("[OK]"))
        #expect(output.contains("[FAIL]"))
        #expect(output.contains("1 succeeded"))
        #expect(output.contains("1 failed"))
        #expect(!output.contains("Warnings"))
    }

    @Test func outputFormatterFailed() {
        let result = PEXRunResult(
            runID: PEXRunID(),
            requestHash: PEXRequestHash("h"),
            status: .failed,
            startedAt: Date(),
            finishedAt: Date(),
            cornerResults: [
                PEXCornerResult(
                    cornerID: "tt", status: .failed,
                    ir: nil,
                    metrics: PEXCornerMetrics(durationSeconds: 0.1, netCount: 0, elementCount: 0)
                ),
            ],
            warnings: [],
            artifacts: PEXArtifactIndex(manifestURL: URL(filePath: "/tmp/m.json"), requestURL: URL(filePath: "/tmp/r.json"), cornerArtifacts: [:]),
            metrics: PEXRunMetrics(totalDurationSeconds: 0.1, cornerCount: 1, successCount: 0, failureCount: 1)
        )

        let formatter = CLIOutputFormatter()
        let output = formatter.formatResult(result)
        #expect(output.contains("failed"))
        #expect(output.contains("[FAIL]"))
        #expect(output.contains("0 succeeded"))
    }

    // MARK: - SummarizeCommand.formatEngineering

    @Test func formatEngineeringValues() throws {
        let cmd = try SummarizeCommand(arguments: ["--run", "/tmp/r"])

        #expect(cmd.formatEngineering(0) == "0")

        // Exact value verification per range
        #expect(cmd.formatEngineering(1.234e9) == "1.234G")
        #expect(cmd.formatEngineering(5.678e6) == "5.678M")
        #expect(cmd.formatEngineering(2.5e3) == "2.500k")
        #expect(cmd.formatEngineering(100.0) == "100.000")
        #expect(cmd.formatEngineering(1.5e-3) == "1.500m")
        #expect(cmd.formatEngineering(4.7e-6) == "4.700u")
        #expect(cmd.formatEngineering(3.3e-9) == "3.300n")
        #expect(cmd.formatEngineering(1.0e-12) == "1.000p")
        #expect(cmd.formatEngineering(2.5e-15) == "2.500f")

        // Scientific notation fallback (below femto)
        let subFemto = cmd.formatEngineering(1e-18)
        #expect(subFemto.contains("e"))

        // Negative values
        #expect(cmd.formatEngineering(-5e-12) == "-5.000p")
        #expect(cmd.formatEngineering(-1.0e-15) == "-1.000f")
    }
}
