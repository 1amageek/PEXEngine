import Testing
import Foundation
@testable import PEXCLICore
@testable import PEXEngine
@testable import PEXCore

@Suite("PEXCLI Tests")
struct PEXCLITests {
    @Test func backannotateCommandParsesRequiredPaths() throws {
        let command = try BackannotateCommand(arguments: [
            "--netlist", "/tmp/source.sp",
            "--ir", "/tmp/tt.json",
            "--output", "/tmp/post.sp",
            "--top-cell", "TOP",
            "--json",
        ])
        #expect(command.sourceNetlistURL.path(percentEncoded: false) == "/tmp/source.sp")
        #expect(command.irURL.path(percentEncoded: false) == "/tmp/tt.json")
        #expect(command.outputURL.path(percentEncoded: false) == "/tmp/post.sp")
        #expect(command.topCell == "TOP")
        #expect(command.jsonOutput)
    }

    @Test func backannotateCommandRejectsMissingIR() {
        do {
            _ = try BackannotateCommand(arguments: ["--netlist", "/tmp/source.sp", "--output", "/tmp/post.sp"])
            #expect(Bool(false), "Expected missing --ir to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("--ir"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func backannotateCommandWritesComposedDeck() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-backannotate-cli-\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sourceURL = tempDir.appending(path: "source.cir")
        let irURL = tempDir.appending(path: "tt.json")
        let outputURL = tempDir.appending(path: "post.cir")
        try Data(".subckt TOP in out\nR1 in out 1k\n.ends TOP\nV1 in 0 1\nXTOP in out TOP\n.end\n".utf8)
            .write(to: sourceURL)
        let inNet = NetName("IN")
        let outNet = NetName("OUT")
        let inNode = NodeName("in")
        let outNode = NodeName("out")
        let ir = ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: [
                ParasiticNet(name: inNet, nodes: [ParasiticNode(name: inNode, kind: .pin, instancePath: nil, coordinate: nil)], totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0),
                ParasiticNet(name: outNet, nodes: [ParasiticNode(name: outNode, kind: .pin, instancePath: nil, coordinate: nil)], totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0),
            ],
            elements: [ParasiticElement(
                id: "Rout",
                kind: .resistor,
                nodeA: NodeRef(netName: inNet, nodeName: inNode),
                nodeB: NodeRef(netName: outNet, nodeName: outNode),
                value: 2,
                source: .extracted
            )],
            metadata: ["topCell": "TOP"]
        )
        try PEXIRSerializer().encode(ir).write(to: irURL)

        try await BackannotateCommand(arguments: [
            "--netlist", sourceURL.path(percentEncoded: false),
            "--ir", irURL.path(percentEncoded: false),
            "--output", outputURL.path(percentEncoded: false),
            "--top-cell", "TOP",
            "--json",
        ]).run()

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(output.contains("XPEX_tt in out PEX_TOP_tt"))
        #expect(output.contains(".subckt PEX_TOP_tt in out"))
    }

    @Test func retryCommandRequiresPersistedManifest() throws {
        let command = try RetryCommand(arguments: ["--run", "/tmp/run/manifest.json", "--json"])
        #expect(command.manifestURL.path(percentEncoded: false) == "/tmp/run/manifest.json")
        #expect(command.jsonOutput)
    }

    @Test func lineageCommandRequiresLeafManifest() throws {
        let command = try LineageCommand(arguments: ["--run", "/tmp/leaf/manifest.json", "--json"])
        #expect(command.manifestURL.path(percentEncoded: false) == "/tmp/leaf/manifest.json")
        #expect(command.jsonOutput)
    }

    @Test func queryCommandParsesNetModuleAndCornerDeltaModes() throws {
        let net = try QueryCommand(arguments: [
            "--run", "/tmp/run", "--net", "VDD", "--corner", "tt", "--json",
        ])
        #expect(net.runPath.path(percentEncoded: false) == "/tmp/run")
        #expect(net.jsonOutput)
        #expect(net.kind == .net(NetName("VDD"), PEXCornerID("tt")))

        let module = try QueryCommand(arguments: [
            "--run", "/tmp/run/manifest.json", "--module", "TOP/u1", "--corner", "ss",
        ])
        #expect(module.kind == .module(InstancePath("TOP/u1"), PEXCornerID("ss")))

        let delta = try QueryCommand(arguments: [
            "--run", "/tmp/run", "--base-corner", "tt", "--target-corner", "ss",
        ])
        #expect(delta.kind == .cornerDelta(PEXCornerID("tt"), PEXCornerID("ss")))
    }

    @Test func queryCommandRejectsAmbiguousModes() {
        do {
            _ = try QueryCommand(arguments: [
                "--run", "/tmp/run", "--net", "VDD", "--module", "TOP", "--corner", "tt",
            ])
            #expect(Bool(false), "Expected ambiguous query mode to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func retryCommandRejectsMissingManifest() {
        do {
            _ = try RetryCommand(arguments: ["--json"])
            #expect(Bool(false), "Expected missing --run to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("retry"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

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
            "--process-profile-id", "sky130.signoff",
            "--pdk-id", "sky130",
            "--process-profile-source", "signoff-pdk-profile.json",
            "--process-requirement", "magic",
            "--pdk-root", "/tmp/pdk",
            "--primary-deck", "/tmp/pdk/libs.tech/magic/sky130A.magicrc",
            "--corner-deck", "tt=/tmp/pdk/libs.tech/magic/sky130A-tt.magicrc",
            "--corner-deck", "ss=/tmp/pdk/libs.tech/magic/sky130A-ss.magicrc",
            "--corner-technology", "ss=/tmp/pdk/technology/sky130B.json",
            "--source-connectivity", "strict",
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
        #expect(params?.processProfile?.profileID == "sky130.signoff")
        #expect(params?.processProfile?.pdkID == "sky130")
        #expect(params?.processProfile?.requirementID == "magic")
        #expect(params?.processProfile?.pdkRoot == "/tmp/pdk")
        #expect(params?.processProfile?.primaryDeckPath == "/tmp/pdk/libs.tech/magic/sky130A.magicrc")
        #expect(params?.processProfile?.cornerDeckPaths == [
            "tt": "/tmp/pdk/libs.tech/magic/sky130A-tt.magicrc",
            "ss": "/tmp/pdk/libs.tech/magic/sky130A-ss.magicrc",
        ])
        #expect(params?.technologyByCorner == ["ss": "/tmp/pdk/technology/sky130B.json"])
        #expect(params?.sourceConnectivityPolicy == .strict)
        #expect(params?.strict == true)
    }

    @Test func extractCommandRejectsUnknownSourceConnectivityPolicy() {
        do {
            _ = try ExtractCommand(arguments: [
                "--layout", "/tmp/l.gds",
                "--netlist", "/tmp/n.sp",
                "--top-cell", "T",
                "--technology", "/tmp/t.json",
                "--backend", "mock",
                "--source-connectivity", "audit",
            ])
            #expect(Bool(false), "Expected unknown source-connectivity policy to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("source-connectivity"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func extractCommandRejectsMalformedCornerDeck() {
        do {
            _ = try ExtractCommand(arguments: [
                "--layout", "/tmp/l.gds",
                "--netlist", "/tmp/n.sp",
                "--top-cell", "T",
                "--technology", "/tmp/t.json",
                "--backend", "mock",
                "--corner-deck", "ss",
            ])
            #expect(Bool(false), "Expected malformed corner deck to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("--corner-deck"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func extractCommandDefaultCorner() throws {
        let cmd = try ExtractCommand(arguments: [
            "--layout", "/tmp/l.gds",
            "--netlist", "/tmp/n.sp",
            "--top-cell", "T",
            "--technology", "/tmp/t.json",
            "--backend", "mock",
        ])
        #expect(cmd.directParams?.corners == ["tt_25c_1v0"])
        #expect(cmd.directParams?.backendID == "mock")
        #expect(cmd.directParams?.strict == true)
        #expect(cmd.includeSummary == false)
        #expect(cmd.summaryTopNets == 10)
    }

    @Test func extractCommandDirectModeRequiresExplicitBackend() {
        do {
            _ = try ExtractCommand(arguments: [
                "--layout", "/tmp/l.gds",
                "--netlist", "/tmp/n.sp",
                "--top-cell", "T",
                "--technology", "/tmp/t.json",
            ])
            #expect(Bool(false), "Expected missing --backend to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("--backend"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func extractCommandCanDisableStrictValidation() throws {
        let cmd = try ExtractCommand(arguments: [
            "--layout", "/tmp/l.gds",
            "--netlist", "/tmp/n.sp",
            "--top-cell", "T",
            "--technology", "/tmp/t.json",
            "--backend", "mock",
            "--non-strict",
        ])
        #expect(cmd.directParams?.strict == false)
    }

    @Test func extractCommandSummaryArguments() throws {
        let cmd = try ExtractCommand(arguments: [
            "--layout", "/tmp/l.gds",
            "--netlist", "/tmp/n.sp",
            "--top-cell", "T",
            "--technology", "/tmp/t.json",
            "--backend", "mock",
            "--summary",
            "--summary-top-nets", "3",
            "--json",
        ])
        #expect(cmd.includeSummary == true)
        #expect(cmd.summaryTopNets == 3)
        #expect(cmd.jsonOutput == true)
    }

    @Test func extractCommandRejectsInvalidSummaryTopNets() {
        do {
            _ = try ExtractCommand(arguments: ["--summary-top-nets", "0"])
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
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

    @Test func extractCommandRejectsUnknownArgument() {
        do {
            _ = try ExtractCommand(arguments: [
                "--layout", "/tmp/l.gds",
                "--netlist", "/tmp/n.sp",
                "--top-cell", "T",
                "--technology", "/tmp/t.json",
                "--unexpected",
            ])
            #expect(Bool(false), "Expected unknown extract argument to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("--unexpected"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    // MARK: - ExtractCommand Request Building

    @Test func buildRequestFromDirectParams() throws {
        let cmd = try ExtractCommand(arguments: [
            "--layout", "/tmp/design.oas",
            "--netlist", "/tmp/netlist.sp",
            "--top-cell", "chip",
            "--technology", "/tmp/tech.json",
            "--backend", "mock",
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
        defer { removeTemporaryItem(tmpDir) }

        let configJSON: [String: Any] = [
            "topCell": "CHIP",
            "backendID": "mock",
            "processProfile": [
                "profileID": "sky130.signoff",
                "pdkID": "sky130",
                "source": "signoff-pdk-profile.json",
                "requirementID": "magic",
                "pdkRoot": "/tmp/pdk",
                "primaryDeckPath": "/tmp/pdk/libs.tech/magic/sky130A.magicrc",
                "cornerDeckPaths": [
                    "tt": "/tmp/pdk/libs.tech/magic/sky130A-tt.magicrc",
                    "ss": "/tmp/pdk/libs.tech/magic/sky130A-ss.magicrc",
                ],
            ],
            "inputs": [
                "layout": "chip.gds",
                "netlist": "chip.sp",
                "technology": "tech.json",
                "technologyByCorner": ["ss": "tech/sky130B.json"],
            ],
            "corners": ["ff_m40c_0v9"],
            "options": [
                "includeCouplingCaps": false,
                "maxParallelJobs": 4,
                "strictValidation": true,
                "minCapacitanceF": 5e-16,
                "minResistanceOhm": 0.05,
                "sourceConnectivityPolicy": "strict",
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
        #expect(request.options.sourceConnectivityPolicy == .strict)
        #expect(request.options.emitRawArtifacts == true)
        #expect(request.options.emitIRJSON == true)
        #expect(request.technologyByCorner["ss"] == .jsonFile(
            tmpDir.appending(path: "tech/sky130B.json")
        ))
        #expect(request.processProfile?.profileID == "sky130.signoff")
        #expect(request.processProfile?.pdkID == "sky130")
        #expect(request.processProfile?.requirementID == "magic")
        #expect(request.processProfile?.cornerDeckPaths["tt"] == "/tmp/pdk/libs.tech/magic/sky130A-tt.magicrc")
    }

    @Test func buildRequestFromConfigFileDefaultsThresholdsToNil() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(tmpDir) }

        let configJSON: [String: Any] = [
            "topCell": "T",
            "backendID": "mock",
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
        #expect(request.options.strictValidation == true)
    }

    @Test func buildRequestFromConfigFileResolvesRelativeProcessDeckPaths() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-relative-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(tmpDir) }

        let configJSON: [String: Any] = [
            "topCell": "TOP",
            "backendID": "mock",
            "processProfile": [
                "pdkRoot": "pdk",
                "primaryDeckPath": "pdk/tt.magicrc",
                "cornerDeckPaths": [
                    "tt": "pdk/tt.magicrc",
                    "ss": "decks/ss.magicrc",
                ],
            ],
            "inputs": [
                "layout": "top.gds",
                "netlist": "top.sp",
                "technology": "tech.json",
            ],
        ]
        let configURL = tmpDir.appending(path: "config.json")
        try JSONSerialization.data(withJSONObject: configJSON, options: []).write(to: configURL)

        let command = try ExtractCommand(arguments: ["--config", configURL.path(percentEncoded: false)])
        let request = try await command.buildRequestFromConfigFile(configURL)
        let base = tmpDir.path(percentEncoded: false)
        #expect(request.processProfile?.pdkRoot == "\(base)/pdk")
        #expect(request.processProfile?.primaryDeckPath == "\(base)/pdk/tt.magicrc")
        #expect(request.processProfile?.cornerDeckPaths["ss"] == "\(base)/decks/ss.magicrc")
    }

    @Test func configModeAppliesProcessProfileCLIOverrides() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-profile-override-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(tmpDir) }
        let configJSON: [String: Any] = [
            "topCell": "TOP",
            "backendID": "mock",
            "processProfile": [
                "pdkRoot": "pdk",
                "cornerDeckPaths": ["tt": "pdk/tt.magicrc", "ss": "pdk/ss.magicrc"],
            ],
            "inputs": ["layout": "top.gds", "netlist": "top.sp", "technology": "tech.json"],
        ]
        let configURL = tmpDir.appending(path: "config.json")
        try JSONSerialization.data(withJSONObject: configJSON, options: []).write(to: configURL)

        let command = try ExtractCommand(arguments: [
            "--config", configURL.path(percentEncoded: false),
            "--pdk-root", "/override/pdk",
            "--corner-deck", "ss=/override/ss.magicrc",
        ])
        let request = try await command.buildRequestFromConfigFile(configURL)
        #expect(request.processProfile?.pdkRoot == "/override/pdk")
        #expect(request.processProfile?.cornerDeckPaths["tt"] == "\(tmpDir.path(percentEncoded: false))/pdk/tt.magicrc")
        #expect(request.processProfile?.cornerDeckPaths["ss"] == "/override/ss.magicrc")
    }

    @Test func buildRequestFromConfigFileRequiresExplicitBackend() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(tmpDir) }

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
        do {
            _ = try await cmd.buildRequestFromConfigFile(configURL)
            #expect(Bool(false), "Expected missing backendID to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("backendID"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func buildRequestFromConfigFileHonorsStrictCLIOverrides() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(tmpDir) }

        let configURL = tmpDir.appending(path: "config.json")

        try writeConfig(strictValidation: true, to: configURL)
        let nonStrictCommand = try ExtractCommand(arguments: [
            "--config",
            configURL.path(percentEncoded: false),
            "--non-strict",
        ])
        let nonStrictRequest = try await nonStrictCommand.buildRequestFromConfigFile(configURL)
        #expect(nonStrictRequest.options.strictValidation == false)

        try writeConfig(strictValidation: false, to: configURL)
        let strictCommand = try ExtractCommand(arguments: [
            "--config",
            configURL.path(percentEncoded: false),
            "--strict",
        ])
        let strictRequest = try await strictCommand.buildRequestFromConfigFile(configURL)
        #expect(strictRequest.options.strictValidation == true)
    }

    @Test func extractJSONOutputCanIncludeMultiCornerSummary() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-extract-summary-\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt", "ss"])

        let recorder = PEXArtifactRecorder(workspace: workspace)
        let serializer = PEXIRSerializer()
        let ttIRURL = workspace.cornerIRURL("tt")
        let ssIRURL = workspace.cornerIRURL("ss")
        try serializer.encode(makeSummaryIR(cornerID: "tt", primaryNet: "OUT_TT")).write(to: ttIRURL)
        try serializer.encode(
            makeSummaryIR(cornerID: "ss", primaryNet: "OUT_SS", capacitanceScale: 2, resistanceScale: 3)
        ).write(to: ssIRURL)
        let ttRecord = try recorder.recordExistingArtifact(
            url: ttIRURL,
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: "tt",
            id: "ir-tt"
        )
        let ssRecord = try recorder.recordExistingArtifact(
            url: ssIRURL,
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: "ss",
            id: "ir-ss"
        )
        let reportURL = workspace.reportURL
        try "{}".write(to: reportURL, atomically: true, encoding: .utf8)
        let reportRecord = try recorder.recordExistingArtifact(
            url: reportURL,
            kind: .report,
            stage: .reporting,
            id: "report-summary"
        )

        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("extract-summary"),
            backendID: "mock",
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [
                PEXArtifactCorner(cornerID: "tt", status: .success, artifactIDs: [ttRecord.id]),
                PEXArtifactCorner(cornerID: "ss", status: .success, artifactIDs: [ssRecord.id]),
            ],
            artifacts: [ttRecord, ssRecord, reportRecord],
            warnings: []
        )
        try PEXArtifactStore(workspace: workspace).saveManifest(manifest)

        let result = try PEXRunResult(
            runID: runID,
            requestHash: PEXRequestHash("extract-summary"),
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            cornerResults: [
                PEXCornerResult(cornerID: "tt", status: .success, ir: nil, metrics: PEXCornerMetrics(durationSeconds: 0.1, netCount: 2, elementCount: 0)),
                PEXCornerResult(cornerID: "ss", status: .success, ir: nil, metrics: PEXCornerMetrics(durationSeconds: 0.1, netCount: 2, elementCount: 0)),
            ],
            warnings: [],
            artifactManifest: manifest,
            manifestURL: workspace.manifestURL,
            metrics: PEXRunMetrics(totalDurationSeconds: 0.2, cornerCount: 2, successCount: 2, failureCount: 0)
        )

        let cmd = try ExtractCommand(arguments: [
            "--layout", "/tmp/l.gds",
            "--netlist", "/tmp/n.sp",
            "--top-cell", "T",
            "--technology", "/tmp/t.json",
            "--backend", "mock",
            "--summary",
            "--summary-top-nets", "1",
            "--json",
        ])
        let output = try cmd.buildJSONOutput(for: result)

        #expect(output.completeness.status == .complete)
        #expect(output.summary?.corners.count == 2)
        #expect(output.summary?.corners.first { $0.cornerID == "tt" }?.topNets.count == 1)
        #expect(output.summary?.corners.first { $0.cornerID == "tt" }?.topNets.first?.name == "OUT_TT")
        #expect(output.summary?.corners.first { $0.cornerID == "ss" }?.topNets.first?.name == "OUT_SS")
        #expect(output.summary?.multiCorner.cornerCount == 2)
        #expect(output.summary?.multiCorner.worstCapacitanceCornerID == "ss")
        #expect(output.summary?.multiCorner.worstResistanceCornerID == "ss")
        #expect(output.summary?.multiCorner.totalCapacitance.spread ?? 0 > 0)
        #expect(output.summary?.multiCorner.totalResistance.spread ?? 0 > 0)
    }

    // MARK: - ParseCorpusCommand

    @Test func parseCorpusCommandArguments() throws {
        let manifestURL = openROADFixtureDirectoryURL().appending(path: "fixture-manifest.json")
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "pex-corpus-\(UUID().uuidString)")
            .appending(path: "report.json")

        let cmd = try ParseCorpusCommand(arguments: [
            "--manifest",
            manifestURL.path(percentEncoded: false),
            "--fixtures-dir",
            openROADFixtureDirectoryURL().path(percentEncoded: false),
            "--out",
            outputURL.path(percentEncoded: false),
            "--json",
        ])

        #expect(cmd.manifestURL == manifestURL)
        #expect(cmd.fixtureDirectory == openROADFixtureDirectoryURL())
        #expect(cmd.outputURL == outputURL)
        #expect(cmd.jsonOutput == true)
    }

    @Test func parseCorpusCommandBuildsOpenROADEvaluationReport() throws {
        let fixtureDirectory = openROADFixtureDirectoryURL()
        let manifestURL = fixtureDirectory.appending(path: "fixture-manifest.json")
        let cmd = try ParseCorpusCommand(arguments: [
            "--manifest",
            manifestURL.path(percentEncoded: false),
            "--fixtures-dir",
            fixtureDirectory.path(percentEncoded: false),
        ])

        let report = try cmd.buildReport()

        #expect(report.status == "passed")
        #expect(report.summary.caseCount == 7)
        #expect(report.summary.failedCaseCount == 0)
        #expect(report.evaluation.passed)
        #expect(report.summary.coverageTagCounts["pex.spef.openroad"] == 7)
        #expect(report.summary.coverageTagCounts["pex.extract.openrcx"] == 7)
        #expect(report.summary.coverageTagCounts["pex.physical-value"] == 7)
        #expect(report.observationSummary.passed)
    }

    @Test func observationFromCorpusReportCommandArguments() throws {
        let observedAt = "2026-06-19T00:00:00Z"
        let cmd = try ObservationFromCorpusReportCommand(arguments: [
            "--report",
            "/tmp/pex-spef-corpus-report.json",
            "--record-id",
            "pex-corpus-1",
            "--observed-at",
            observedAt,
            "--json",
        ])

        #expect(cmd.reportURL.path(percentEncoded: false) == "/tmp/pex-spef-corpus-report.json")
        #expect(cmd.recordID == "pex-corpus-1")
        #expect(cmd.observedAt == Date(timeIntervalSince1970: 1_781_827_200))
        #expect(cmd.jsonOutput == true)
    }

    @Test func observationFromCorpusReportBuildsRawObservationExport() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(tempDir) }

        let manifestURL = openROADFixtureDirectoryURL().appending(path: "fixture-manifest.json")
        let report = try SPEFCorpusRunner().run(manifestURL: manifestURL)
        let reportURL = tempDir.appending(path: "pex-spef-corpus-report.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL)

        let cmd = try ObservationFromCorpusReportCommand(
            arguments: [
                "--report",
                reportURL.path(percentEncoded: false),
                "--record-id",
                "pex-spef-corpus-test",
                "--observed-at",
                "2026-06-19T00:00:00Z",
            ]
        )

        let export = try cmd.buildExport()
        #expect(export.status == "passed")
        #expect(export.reportSHA256.count == 64)
        #expect(export.observationRecord.recordID == "pex-spef-corpus-test")
        #expect(export.reportArtifact.kind == .report)
        #expect(export.reportArtifact.format == .json)
        #expect(export.reportArtifact.digest.hexadecimalValue == export.reportSHA256)
        #expect(export.observationRecord.observedAt == "2026-06-19T00:00:00.000Z")
        #expect(export.observationRecord.observations.passed)
        #expect(export.observationRecord.observations.observedCounts["caseCount"] == 7)
        #expect(export.observationRecord.observations.observedCounts["failureOccurrenceCount"] == 0)
        #expect(export.observationRecord.observations.observedCounts["failureCodeCount"] == 0)
        #expect(export.observationRecord.observations.observedCounts["failureCodeKindCount"] == 0)
        #expect(export.observationRecord.observations.observedCounts["failureCategoryCount"] == 0)
        #expect(export.observationRecord.observations.observedCounts["failureCategoryKindCount"] == 0)
        #expect(export.observationRecord.observations.observedCounts["requiredCoverageTagCount"] == 14)
        #expect(export.observationRecord.observations.observedCounts["coveredRequiredCoverageTagCount"] == 14)
    }

    @Test func evidencePacketFromCorpusReportBuildsDecisionMaterialPacket() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-evidence-packet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(tempDir) }

        let manifestURL = openROADFixtureDirectoryURL().appending(path: "fixture-manifest.json")
        let report = try SPEFCorpusRunner().run(manifestURL: manifestURL)
        let reportURL = tempDir.appending(path: "pex-spef-corpus-report.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL)

        let cmd = try EvidencePacketFromCorpusReportCommand(
            arguments: [
                "--report",
                reportURL.path(percentEncoded: false),
                "--packet-id",
                "packet-test",
            ]
        )

        let packet = try cmd.buildPacket()

        #expect(packet.schemaVersion == PEXEvidencePacket.currentSchemaVersion)
        #expect(packet.packetID == "packet-test")
        #expect(packet.domain == "pex.parasitic-evidence")
        #expect(packet.subject.backendID == "openrcx")
        #expect(packet.inputs.count >= 2)
        #expect(packet.readiness.contains { $0.status == .unknown && $0.component == "external-extractor-execution" })
        #expect(packet.normalizedViews.contains { $0.kind == "parasitic-ir-summary" })
        #expect(packet.metrics.contains { $0.name == "totalGroundCapF" && $0.unit == "F" })
        #expect(packet.confidence.level == .high)
        #expect(packet.decisionHints.contains { $0.action == "compare_physical_metrics_against_design_intent" })
        #expect(packet.coverageTags.contains("pex.physical-value"))
    }

    @Test func evidencePacketFromCorpusReportCommandWritesRoundTrippablePacketFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-evidence-packet-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(tempDir) }

        let manifestURL = openROADFixtureDirectoryURL().appending(path: "fixture-manifest.json")
        let report = try SPEFCorpusRunner().run(manifestURL: manifestURL)
        let reportURL = tempDir.appending(path: "pex-spef-corpus-report.json")
        let packetURL = tempDir.appending(path: "packets/pex-evidence-packet.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL)

        let cmd = try EvidencePacketFromCorpusReportCommand(
            arguments: [
                "--report",
                reportURL.path(percentEncoded: false),
                "--out",
                packetURL.path(percentEncoded: false),
                "--packet-id",
                "packet-write-test",
            ]
        )

        #expect(try await cmd.run())
        let decoded = try JSONDecoder().decode(PEXEvidencePacket.self, from: Data(contentsOf: packetURL))

        #expect(decoded.packetID == "packet-write-test")
        #expect(decoded.subject.backendID == "openrcx")
        #expect(decoded.inputs.contains {
            $0.reference.locator.role == .input
                && $0.reference.locator.kind == .other
                && $0.reference.locator.format == .json
        })
        #expect(decoded.artifacts.isEmpty)
        #expect(decoded.metrics.contains { $0.name == "caseCount" && $0.unit == "count" })
        #expect(decoded.confidence.level == .high)
    }

    @Test func evidencePacketFromExtractorReportSeparatesReadinessFromPhysicalMismatch() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-extractor-evidence-packet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(tempDir) }

        let report = PEXExternalExtractorCorpusReport(
            schemaVersion: 1,
            corpusSpec: "Fixtures/ExternalExtractor/pex-magic-corpus.json",
            extractorBackendID: "magic",
            status: "failed",
            summary: PEXExternalExtractorCorpusReport.Summary(
                caseCount: 1,
                passedCaseCount: 0,
                failedCaseCount: 1,
                passRate: 0,
                coverageTagCounts: [
                    "pex.magic": 1,
                    "pex.physical-value": 1,
                    "pex.ground-cap": 1,
                ],
                totalGroundCapF: 1.4e-15,
                totalCouplingCapF: 0,
                totalCapacitanceF: 1.4e-15,
                totalResistanceOhm: 0,
                totalNetCount: 1,
                totalElementCount: 1
            ),
            evaluation: PEXExternalExtractorCorpusReport.Evaluation(
                policy: PEXExternalExtractorCorpusReport.Policy(
                    requiredCoverageTags: ["pex.magic", "pex.physical-value"],
                    minimumPassRate: 1
                ),
                failures: [
                    PEXExternalExtractorCorpusReport.EvaluationFailure(
                        code: "case_failure",
                        caseID: "plate",
                        failureCode: "ground_cap_out_of_tolerance"
                    )
                ]
            ),
            cases: [
                PEXExternalExtractorCorpusReport.CaseResult(
                    caseID: "plate",
                    status: "failed",
                    topCell: "pex_plate",
                    corner: "tt",
                    layoutPath: "pex_plate.gds",
                    sourceNetlistPath: "source.cir",
                    technologyPath: "technology.json",
                    outputDirectory: "run",
                    manifestPath: "run/manifest.json",
                    irPath: "run/ir/tt.json",
                    coverageTags: ["pex.magic", "pex.physical-value", "pex.ground-cap"],
                    totalGroundCapF: 1.4e-15,
                    totalCouplingCapF: 0,
                    totalCapacitanceF: 1.4e-15,
                    totalResistanceOhm: 0,
                    expectedGroundCapF: 4.2e-15,
                    groundCapToleranceF: 2e-16,
                    groundCapErrorF: 2.8e-15,
                    netCount: 1,
                    elementCount: 1,
                    failures: [
                        PEXExternalExtractorCorpusReport.CaseFailure(
                            code: "ground_cap_out_of_tolerance",
                            metric: "totalGroundCapF",
                            expected: 4.2e-15,
                            observed: 1.4e-15,
                            tolerance: 2e-16
                        )
                    ]
                )
            ]
        )
        let reportURL = tempDir.appending(path: "pex-real-extractor-report.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL)

        let cmd = try EvidencePacketFromExtractorReportCommand(
            arguments: [
                "--report",
                reportURL.path(percentEncoded: false),
                "--packet-id",
                "extractor-packet-test",
            ]
        )

        let packet = try cmd.buildPacket()

        #expect(packet.packetID == "extractor-packet-test")
        #expect(packet.subject.kind == "external-extractor-corpus")
        #expect(packet.subject.backendID == "magic")
        #expect(packet.readiness.contains { $0.component == "external-extractor-execution" && $0.status == .ready })
        #expect(packet.diagnostics.contains { $0.category == "physical_bound_mismatch" && $0.expectedValue == 4.2e-15 })
        #expect(packet.metrics.contains { $0.name == "totalGroundCapF" && $0.caseID == "plate" && $0.expectedValue == 4.2e-15 })
        #expect(packet.decisionHints.contains { $0.action == "check_extractor_units" })
        #expect(packet.confidence.level == .medium)
    }

    @Test func evidencePacketFromExtractorReportCommandWritesBlockedExecutionPacket() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-blocked-extractor-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(tempDir) }

        let report = PEXExternalExtractorCorpusReport(
            schemaVersion: 1,
            corpusSpec: "Fixtures/ExternalExtractor/pex-magic-corpus.json",
            extractorBackendID: "magic",
            status: "failed",
            summary: PEXExternalExtractorCorpusReport.Summary(
                caseCount: 1,
                passedCaseCount: 0,
                failedCaseCount: 1,
                passRate: 0,
                coverageTagCounts: ["pex.magic": 1],
                totalGroundCapF: 0,
                totalCouplingCapF: 0,
                totalCapacitanceF: 0,
                totalResistanceOhm: 0,
                totalNetCount: 0,
                totalElementCount: 0
            ),
            evaluation: PEXExternalExtractorCorpusReport.Evaluation(
                policy: PEXExternalExtractorCorpusReport.Policy(
                    requiredCoverageTags: ["pex.magic", "pex.physical-value"],
                    minimumPassRate: 1
                ),
                failures: [
                    PEXExternalExtractorCorpusReport.EvaluationFailure(
                        code: "case_failure",
                        caseID: "plate",
                        failureCode: "extract_command_failed"
                    ),
                    PEXExternalExtractorCorpusReport.EvaluationFailure(
                        code: "required_coverage_missing",
                        missingTags: ["pex.physical-value"]
                    ),
                ]
            ),
            cases: [
                PEXExternalExtractorCorpusReport.CaseResult(
                    caseID: "plate",
                    status: "failed",
                    topCell: "pex_plate",
                    corner: "tt",
                    layoutPath: "pex_plate.gds",
                    sourceNetlistPath: "source.cir",
                    technologyPath: "technology.json",
                    outputDirectory: "run",
                    manifestPath: nil,
                    irPath: nil,
                    coverageTags: ["pex.magic"],
                    failures: [
                        PEXExternalExtractorCorpusReport.CaseFailure(
                            code: "extract_command_failed",
                            message: "External extractor exited before producing normalized PEX output.",
                            status: "exit(1)"
                        )
                    ]
                )
            ]
        )
        let reportURL = tempDir.appending(path: "pex-real-extractor-report.json")
        let packetURL = tempDir.appending(path: "packets/pex-extractor-packet.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL)

        let cmd = try EvidencePacketFromExtractorReportCommand(
            arguments: [
                "--report",
                reportURL.path(percentEncoded: false),
                "--out",
                packetURL.path(percentEncoded: false),
                "--packet-id",
                "blocked-extractor-packet",
            ]
        )

        #expect(try await cmd.run())
        let decoded = try JSONDecoder().decode(PEXEvidencePacket.self, from: Data(contentsOf: packetURL))

        #expect(decoded.packetID == "blocked-extractor-packet")
        #expect(decoded.readiness == [
            PEXEvidenceReadiness(
                component: "external-extractor-execution",
                status: .blocked,
                reason: "Every external extractor case failed before usable normalized PEX evidence was produced.",
                suggestedActions: [
                    "check_extractor_readiness_before_rerun",
                    "inspect_extractor_command_output",
                ]
            )
        ])
        #expect(decoded.diagnostics.contains {
            $0.code == "extract_command_failed"
                && $0.category == "extractor_execution"
                && $0.severity == .blocked
        })
        #expect(decoded.decisionHints.contains { $0.action == "check_extractor_readiness_before_rerun" })
        #expect(decoded.confidence.level == .low)
    }

    @Test func auditExtractorPhysicalBoundsCommandWritesAgentReadableAudit() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-physical-bounds-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(tempDir) }

        let report = PEXExternalExtractorCorpusReport(
            schemaVersion: 1,
            corpusSpec: "Fixtures/ExternalExtractor/pex-magic-corpus.json",
            extractorBackendID: "magic",
            status: "passed",
            summary: PEXExternalExtractorCorpusReport.Summary(
                caseCount: 1,
                passedCaseCount: 1,
                failedCaseCount: 0,
                passRate: 1,
                coverageTagCounts: [
                    "pex.magic": 1,
                    "pex.physical-value": 1,
                    "pex.ground-cap": 1,
                    "pex.resistance": 1,
                ],
                totalGroundCapF: 4.2e-15,
                totalCouplingCapF: 0,
                totalCapacitanceF: 4.2e-15,
                totalResistanceOhm: 12,
                totalNetCount: 1,
                totalElementCount: 2
            ),
            evaluation: PEXExternalExtractorCorpusReport.Evaluation(
                policy: PEXExternalExtractorCorpusReport.Policy(
                    requiredCoverageTags: ["pex.magic", "pex.physical-value"],
                    minimumPassRate: 1
                ),
                failures: []
            ),
            cases: [
                PEXExternalExtractorCorpusReport.CaseResult(
                    caseID: "plate",
                    status: "passed",
                    topCell: "pex_plate",
                    corner: "tt",
                    layoutPath: "pex_plate.gds",
                    outputDirectory: "run",
                    manifestPath: "run/manifest.json",
                    irPath: "run/ir/tt.json",
                    coverageTags: ["pex.magic", "pex.physical-value", "pex.ground-cap", "pex.resistance"],
                    totalGroundCapF: 4.2e-15,
                    totalResistanceOhm: 12,
                    expectedGroundCapF: 4.2e-15,
                    expectedResistanceOhm: 12,
                    groundCapToleranceF: 2e-16,
                    resistanceToleranceOhm: 0.5
                )
            ]
        )
        let reportURL = tempDir.appending(path: "pex-real-extractor-report.json")
        let auditURL = tempDir.appending(path: "audit/pex-physical-bounds-audit.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL)

        let cmd = try AuditExtractorPhysicalBoundsCommand(arguments: [
            "--report",
            reportURL.path(percentEncoded: false),
            "--out",
            auditURL.path(percentEncoded: false),
            "--audit-id",
            "pex-bounds-audit",
        ])

        #expect(try await cmd.run())
        let audit = try JSONDecoder().decode(
            PEXExternalExtractorPhysicalBoundsAudit.self,
            from: Data(contentsOf: auditURL)
        )

        #expect(audit.auditID == "pex-bounds-audit")
        #expect(audit.status == .satisfied)
        #expect(audit.summary.declaredMetricCount == 2)
        #expect(audit.summary.evaluatedMetricCount == 2)
        #expect(audit.summary.passRate == 1)
        #expect(audit.diagnostics.isEmpty)
        #expect(audit.metricSummaries.contains {
            $0.metricID == "totalResistanceOhm"
                && $0.unit == "ohm"
                && $0.passedCount == 1
        })
    }

    @Test func auditExtractorPhysicalBoundsCommandReturnsFalseAndWritesDiagnosticsForIncompleteAudit() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-physical-bounds-incomplete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(tempDir) }

        let report = makePhysicalBoundsCLIReport(cases: [
            PEXExternalExtractorCorpusReport.CaseResult(
                caseID: "retained-run-without-bounds",
                status: "passed",
                corner: "tt",
                coverageTags: ["pex.magic", "pex.physical-value", "pex.ground-cap"],
                totalGroundCapF: 1.2e-15,
                totalResistanceOhm: 8
            ),
        ])
        let reportURL = tempDir.appending(path: "pex-real-extractor-report.json")
        let auditURL = tempDir.appending(path: "audit/pex-physical-bounds-audit.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL)

        let cmd = try AuditExtractorPhysicalBoundsCommand(arguments: [
            "--report",
            reportURL.path(percentEncoded: false),
            "--out",
            auditURL.path(percentEncoded: false),
        ])

        #expect(try await cmd.run() == false)
        let audit = try JSONDecoder().decode(
            PEXExternalExtractorPhysicalBoundsAudit.self,
            from: Data(contentsOf: auditURL)
        )

        #expect(audit.status == .incomplete)
        #expect(audit.summary.declaredMetricCount == 0)
        #expect(audit.diagnostics.contains {
            $0.code == "physical_bound_missing_declarations"
                && $0.metricID == "physical-bounds"
                && $0.suggestedActions.contains("declare_external_pex_expected_bounds")
        })
    }

    @Test func auditExtractorPhysicalBoundsCommandRejectsPartiallyUndeclaredPhysicalValueCase() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-physical-bounds-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(tempDir) }

        let report = makePhysicalBoundsCLIReport(cases: [
            PEXExternalExtractorCorpusReport.CaseResult(
                caseID: "plate-pass",
                status: "passed",
                corner: "tt",
                coverageTags: ["pex.magic", "pex.physical-value", "pex.ground-cap"],
                totalGroundCapF: 1.05e-15,
                expectedGroundCapF: 1e-15,
                groundCapToleranceF: 1e-16
            ),
            PEXExternalExtractorCorpusReport.CaseResult(
                caseID: "plate-missing-bounds",
                status: "passed",
                corner: "tt",
                coverageTags: ["pex.magic", "pex.physical-value", "pex.ground-cap"],
                totalGroundCapF: 1.2e-15
            ),
        ])
        let reportURL = tempDir.appending(path: "pex-real-extractor-report.json")
        let auditURL = tempDir.appending(path: "audit/pex-physical-bounds-audit.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL)

        let cmd = try AuditExtractorPhysicalBoundsCommand(arguments: [
            "--report",
            reportURL.path(percentEncoded: false),
            "--out",
            auditURL.path(percentEncoded: false),
        ])

        #expect(try await cmd.run() == false)
        let audit = try JSONDecoder().decode(
            PEXExternalExtractorPhysicalBoundsAudit.self,
            from: Data(contentsOf: auditURL)
        )

        #expect(audit.status == .incomplete)
        #expect(audit.summary.declaredMetricCount == 1)
        #expect(audit.diagnostics.contains {
            $0.code == "physical_bound_missing_declarations"
                && $0.caseID == "plate-missing-bounds"
                && $0.metricID == "totalGroundCapF"
        })
    }

    @Test func evidencePacketCommandsRejectMissingReportArguments() {
        do {
            _ = try EvidencePacketFromCorpusReportCommand(arguments: [])
            #expect(Bool(false), "Expected missing corpus report argument to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }

        do {
            _ = try EvidencePacketFromExtractorReportCommand(arguments: ["--report"])
            #expect(Bool(false), "Expected missing extractor report path to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }

        do {
            _ = try AuditExtractorPhysicalBoundsCommand(arguments: ["--report"])
            #expect(Bool(false), "Expected missing physical bounds audit report path to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func evidencePacketCommandsRejectUnknownArgumentsAfterReportPath() {
        do {
            _ = try EvidencePacketFromCorpusReportCommand(arguments: [
                "--report",
                "/tmp/pex-corpus-report.json",
                "--unexpected",
            ])
            #expect(Bool(false), "Expected unknown corpus packet argument to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }

        do {
            _ = try EvidencePacketFromExtractorReportCommand(arguments: [
                "--report",
                "/tmp/pex-extractor-report.json",
                "--unexpected",
            ])
            #expect(Bool(false), "Expected unknown extractor packet argument to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }

        do {
            _ = try AuditExtractorPhysicalBoundsCommand(arguments: [
                "--report",
                "/tmp/pex-extractor-report.json",
                "--unexpected",
            ])
            #expect(Bool(false), "Expected unknown physical bounds audit argument to fail")
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

    @Test func validateTechCommandRejectsUnknownArgument() {
        do {
            _ = try ValidateTechCommand(arguments: ["--technology", "/tmp/tech.json", "--unexpected"])
            #expect(Bool(false), "Expected unknown validate-tech argument to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("--unexpected"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func validateTechCommandStrictJSONRejectsInvalidTechnology() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "pex_validate_tech_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(tempDir) }

        let technology = TechnologyIR(
            processName: "",
            stack: [],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )
        let technologyURL = tempDir.appending(path: "technology.json")
        try JSONEncoder().encode(technology).write(to: technologyURL)
        let command = try ValidateTechCommand(arguments: [
            "--technology", technologyURL.path(percentEncoded: false),
            "--strict", "--json",
        ])

        do {
            try await command.run()
            #expect(Bool(false), "Strict JSON validation must reject an empty technology")
        } catch let error as PEXError {
            #expect(error.kind == .technologyResolutionFailed)
        } catch {
            #expect(Bool(false), "Unexpected validation error: \(error)")
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

    @Test func summarizeCommandRejectsUnknownArgument() {
        do {
            _ = try SummarizeCommand(arguments: ["--run", "/tmp/r", "--unexpected"])
            #expect(Bool(false), "Expected unknown summarize argument to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("--unexpected"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func summarizeCommandUsesManifestIRFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-summary-\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let cornerID = PEXCornerID("tt")
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: [cornerID])

        let customIRDirectory = workspace.runDirectory.appending(path: "custom-ir")
        try FileManager.default.createDirectory(at: customIRDirectory, withIntermediateDirectories: true)
        let ir = ParasiticIR(
            version: "1.0",
            cornerID: cornerID,
            units: .canonical,
            nets: [
                ParasiticNet(name: NetName("OUT"), nodes: [], totalGroundCapF: 2e-12, totalCouplingCapF: 1e-12, totalResistanceOhm: 42)
            ],
            elements: [],
            metadata: [:]
        )
        let serializer = PEXIRSerializer()
        let irURL = customIRDirectory.appending(path: "tt-custom.json")
        try serializer.encode(ir).write(to: irURL)
        let irRecord = try PEXArtifactRecorder(workspace: workspace).recordExistingArtifact(
            url: irURL,
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: cornerID,
            id: "ir-tt"
        )

        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("summary"),
            backendID: "mock",
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [
                PEXArtifactCorner(
                    cornerID: cornerID,
                    status: .success,
                    artifactIDs: [irRecord.id]
                )
            ],
            artifacts: [irRecord],
            warnings: []
        )
        try PEXArtifactStore(workspace: workspace).saveManifest(manifest)

        let cmd = try SummarizeCommand(arguments: [
            "--run",
            workspace.runDirectory.path(percentEncoded: false),
        ])
        let output = try cmd.buildSummary()
        let corner = try #require(output.summary.corners.first)
        #expect(output.manifestURL == workspace.manifestURL)
        #expect(output.completeness.status == .complete)
        #expect(corner.netCount == 1)
        #expect(corner.elementCount == 0)
        #expect(corner.topNets.first?.name == "OUT")
    }

    @Test func summarizeCommandAcceptsManifestPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "pex-summary-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt"])
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("summary"),
            backendID: "mock",
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [],
            artifacts: [],
            warnings: []
        )
        try PEXArtifactStore(workspace: workspace).saveManifest(manifest)

        let cmd = try SummarizeCommand(arguments: [
            "--run",
            workspace.manifestURL.path(percentEncoded: false),
        ])
        let output = try cmd.buildSummary()

        #expect(output.manifestURL == workspace.manifestURL)
        #expect(output.summary.runID == runID.description)
    }

}

private func removeTemporaryItem(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
    }
}

private func openROADFixtureDirectoryURL() -> URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "PEXParsersTests")
        .appending(path: "Fixtures")
        .appending(path: "OpenROAD")
}

private func writeConfig(strictValidation: Bool, to url: URL) throws {
    let configJSON: [String: Any] = [
        "topCell": "T",
        "backendID": "mock",
        "inputs": [
            "layout": "a.gds",
            "netlist": "a.sp",
            "technology": "t.json",
        ],
        "options": [
            "strictValidation": strictValidation,
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: configJSON, options: .prettyPrinted)
    try data.write(to: url)
}

private func makeSummaryIR(
    cornerID: PEXCornerID,
    primaryNet: String,
    capacitanceScale: Double = 1,
    resistanceScale: Double = 1
) -> ParasiticIR {
    ParasiticIR(
        version: "1.0",
        cornerID: cornerID,
        units: .canonical,
        nets: [
            ParasiticNet(
                name: NetName(primaryNet),
                nodes: [],
                totalGroundCapF: 3e-12 * capacitanceScale,
                totalCouplingCapF: 1e-12 * capacitanceScale,
                totalResistanceOhm: 40 * resistanceScale
            ),
            ParasiticNet(
                name: NetName("SMALL_\(cornerID.value)"),
                nodes: [],
                totalGroundCapF: 1e-15 * capacitanceScale,
                totalCouplingCapF: 0,
                totalResistanceOhm: 1 * resistanceScale
            ),
        ],
        elements: [],
        metadata: [:]
    )
}

private func makePhysicalBoundsCLIReport(
    cases: [PEXExternalExtractorCorpusReport.CaseResult]
) -> PEXExternalExtractorCorpusReport {
    let coverageTagCounts = cases
        .flatMap(\.coverageTags)
        .reduce(into: [String: Int]()) { counts, tag in
            counts[tag, default: 0] += 1
        }
    let passedCaseCount = cases.filter { $0.status == "passed" }.count
    let failedCaseCount = cases.count - passedCaseCount
    let passRate = cases.isEmpty ? 0 : Double(passedCaseCount) / Double(cases.count)

    return PEXExternalExtractorCorpusReport(
        schemaVersion: 1,
        corpusSpec: "Fixtures/ExternalExtractor/pex-magic-corpus.json",
        extractorBackendID: "magic",
        status: failedCaseCount == 0 ? "passed" : "failed",
        summary: PEXExternalExtractorCorpusReport.Summary(
            caseCount: cases.count,
            passedCaseCount: passedCaseCount,
            failedCaseCount: failedCaseCount,
            passRate: passRate,
            coverageTagCounts: coverageTagCounts,
            totalGroundCapF: cases.compactMap(\.totalGroundCapF).reduce(0, +),
            totalCouplingCapF: cases.compactMap(\.totalCouplingCapF).reduce(0, +),
            totalCapacitanceF: cases.compactMap(\.totalCapacitanceF).reduce(0, +),
            totalResistanceOhm: cases.compactMap(\.totalResistanceOhm).reduce(0, +),
            totalNetCount: cases.compactMap(\.netCount).reduce(0, +),
            totalElementCount: cases.compactMap(\.elementCount).reduce(0, +)
        ),
        evaluation: PEXExternalExtractorCorpusReport.Evaluation(
            policy: PEXExternalExtractorCorpusReport.Policy(
                requiredCoverageTags: ["pex.magic", "pex.physical-value"],
                minimumPassRate: 1
            ),
            failures: []
        ),
        cases: cases
    )
}
