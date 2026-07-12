import Testing
import Foundation
@testable import PEXCore
@testable import PEXAdapters
@testable import PEXParsers
@testable import PEXPersistence
@testable import PEXRuntime

@Suite("PEXRuntime Tests")
struct PEXRuntimeTests {
    @Test func configMapperMapsCorrectly() throws {
        let config = PEXProjectConfig(
            topCell: "INVERTER",
            backendID: "mock",
            corners: ["tt_25c_1v0", "ss_125c_0v81"]
        )
        let configURL = URL(filePath: "/tmp/project/pex-config.json")
        let mapper = PEXConfigMapper()
        let request = try mapper.mapToRunRequest(config: config, configFileURL: configURL)

        #expect(request.topCell == "INVERTER")
        #expect(request.backendSelection.backendID == "mock")
        #expect(request.corners.count == 2)
        #expect(request.layoutURL.path(percentEncoded: false).contains("top.oas"))
    }

    @Test func configMapperRejectsMissingBackendID() throws {
        let config = PEXProjectConfig(topCell: "INVERTER")
        let configURL = URL(filePath: "/tmp/project/pex-config.json")
        let mapper = PEXConfigMapper()

        do {
            _ = try mapper.mapToRunRequest(config: config, configFileURL: configURL)
            #expect(Bool(false), "Expected missing backendID to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("backendID"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test func configMapperAbsolutePaths() throws {
        let config = PEXProjectConfig(
            topCell: "TOP",
            backendID: "mock",
            corners: ["tt"],
            inputs: PEXProjectConfig.InputPaths(
                layout: "/absolute/path/layout.gds",
                netlist: "/absolute/path/netlist.cir",
                technology: "/absolute/path/tech.json"
            ),
            output: PEXProjectConfig.OutputPaths(workspace: "/absolute/output")
        )
        let configURL = URL(filePath: "/tmp/project/pex-config.json")
        let mapper = PEXConfigMapper()
        let request = try mapper.mapToRunRequest(config: config, configFileURL: configURL)

        // Absolute paths should be preserved, not resolved relative to config dir
        #expect(request.layoutURL.path(percentEncoded: false) == "/absolute/path/layout.gds")
        #expect(request.sourceNetlistURL.path(percentEncoded: false) == "/absolute/path/netlist.cir")
    }

    @Test func configMapperMapsPerCornerTechnologyPaths() throws {
        let config = PEXProjectConfig(
            topCell: "TOP",
            backendID: "mock",
            corners: ["tt", "ss"],
            inputs: PEXProjectConfig.InputPaths(
                layout: "layout.gds",
                netlist: "source.cir",
                technology: "tech/sky130A.json",
                technologyByCorner: ["ss": "tech/sky130B.json"]
            )
        )
        let configURL = URL(filePath: "/tmp/project/pex-config.json")
        let request = try PEXConfigMapper().mapToRunRequest(config: config, configFileURL: configURL)

        #expect(request.technologyByCorner["ss"] == .jsonFile(URL(filePath: "/tmp/project/tech/sky130B.json")))
    }

    @Test func configMapperResolvesProcessProfileDeckPathsRelativeToConfig() throws {
        let config = PEXProjectConfig(
            topCell: "TOP",
            backendID: "magic",
            processProfile: PEXProcessProfileReference(
                profileID: "sky130",
                pdkRoot: "pdk/sky130A",
                primaryDeckPath: "pdk/sky130A/libs.tech/magic/sky130A.magicrc",
                cornerDeckPaths: [
                    "tt": "pdk/sky130A/libs.tech/magic/sky130A.magicrc",
                    "ss": "pdk/sky130B/libs.tech/magic/sky130B.magicrc",
                ]
            ),
            corners: ["tt", "ss"]
        )
        let request = try PEXConfigMapper().mapToRunRequest(
            config: config,
            configFileURL: URL(filePath: "/tmp/project/pex-config.json")
        )

        #expect(request.processProfile?.pdkRoot == "/tmp/project/pdk/sky130A")
        #expect(request.processProfile?.cornerDeckPaths["ss"] == "/tmp/project/pdk/sky130B/libs.tech/magic/sky130B.magicrc")
    }

    @Test func technologyResolverInline() throws {
        let tech = TechnologyIR(
            processName: "test",
            stack: [],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )
        let resolver = TechnologyResolver()
        let resolved = try resolver.resolve(.inline(tech))
        #expect(resolved.processName == "test")
    }

    @Test func endToEndWithMockAdapter() async throws {
        let engine = DefaultPEXEngine.withDefaults()

        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_test_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir)

        let tech = TechnologyIR(
            processName: "test_process",
            stack: [TechnologyLayer(name: "M1", order: 0, thickness: 0.1, material: "copper", resistivity: 1.7e-8)],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )

        let request = PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [PEXCorner(id: "tt_25c_1v0"), PEXCorner(id: "ss_125c_0v81")],
            technology: .inline(tech),
            backendSelection: .mock(),
            options: .default,
            workingDirectory: tempDir
        )

        let result = try await engine.run(request)

        #expect(result.status == .success)
        #expect(result.cornerResults.count == 2)
        #expect(result.metrics.successCount == 2)
        #expect(result.metrics.failureCount == 0)
        #expect(result.extractorRun?.readiness.status == .ready)
        #expect(result.extractorRun?.request.backendID == "mock")
        #expect(result.extractorRun?.request.corners.count == 2)
        #expect(result.extractorRun?.cornerResults.count == 2)
        #expect(result.extractorRun?.cornerResults.allSatisfy { $0.spefRoundTripArtifactID != nil } == true)
        #expect(result.extractorRun?.cornerResults.allSatisfy { $0.spiceBackannotationArtifactID != nil } == true)
        #expect(result.extractorRun?.cornerResults.allSatisfy { $0.sourceConnectivityArtifactID != nil } == true)
        #expect(result.extractorRun?.cornerResults.allSatisfy { $0.unitSystem == "canonical" } == true)
        #expect(result.extractorRun?.cornerResults.allSatisfy { ($0.totalCapacitanceF ?? 0) > 0 } == true)
        #expect(result.extractorRun?.multiCorner.comparisonStatus == .comparable)
        #expect(result.extractorRun?.multiCorner.successfulCornerCount == 2)
        #expect(result.extractorRun?.multiCorner.totalCapacitance.observedCornerCount == 2)
        #expect(result.extractorRun?.multiCorner.totalResistance.observedCornerCount == 2)
        #expect(result.artifacts.extractorRun?.readiness.status == .ready)
        #expect(result.artifacts.extractorRun?.multiCorner.comparisonStatus == .comparable)
        #expect(result.artifacts.artifacts(kind: .spefRoundTrip).count == 2)
        #expect(result.artifacts.artifacts(kind: .spiceBackannotation).count == 2)
        #expect(result.artifacts.artifacts(kind: .sourceConnectivityReport).count == 2)
        #expect(result.warnings.count == 22)
        #expect(result.artifacts.warnings == result.warnings)
        #expect(result.warnings.allSatisfy { $0.stage == .irValidation })
        #expect(Set(result.warnings.compactMap(\.cornerID)) == Set([PEXCornerID("tt_25c_1v0"), PEXCornerID("ss_125c_0v81")]))

        let manifestArtifactIDs = Set(result.artifacts.artifacts.map(\.id))
        let extractorRun = try #require(result.extractorRun)
        for summary in extractorRun.cornerResults {
            #expect(summary.warningCount == 11)
            #expect(summary.rawOutputCount == 1)
            let parasiticIRArtifactID = try #require(summary.parasiticIRArtifactID)
            let spefRoundTripArtifactID = try #require(summary.spefRoundTripArtifactID)
            let spiceBackannotationArtifactID = try #require(summary.spiceBackannotationArtifactID)
            #expect(manifestArtifactIDs.contains(parasiticIRArtifactID))
            #expect(manifestArtifactIDs.contains(spefRoundTripArtifactID))
            #expect(manifestArtifactIDs.contains(spiceBackannotationArtifactID))
            #expect(summary.rawOutputArtifactIDs.allSatisfy { manifestArtifactIDs.contains($0) })
        }

        for cr in result.cornerResults {
            #expect(cr.status == .success)
            #expect(cr.ir != nil)
            #expect(cr.metrics.netCount > 0)
            #expect(cr.metrics.elementCount > 0)
            #expect(cr.warnings.count == 11)
            #expect(cr.warnings.allSatisfy { $0.stage == .irValidation && $0.cornerID == cr.cornerID })
            #expect(cr.warnings.filter { $0.message.contains("disconnectedNode") }.count == 10)
            #expect(cr.warnings.contains { $0.message.contains("Source-netlist connectivity") })
        }

    }

    @Test func mockGoldenCorpusMatchesExpectedParasiticTotals() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_golden_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir)
        let result = try await DefaultPEXEngine.withDefaults().run(PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(makeTestTech()),
            backendSelection: .mock(),
            options: .default,
            workingDirectory: tempDir
        ))
        let ir = try #require(result.cornerResults.first?.ir)
        let capacitorElements = ir.elements.filter { $0.kind == .capacitor }
        let couplingElements = ir.elements.filter { $0.kind == .coupling }
        let resistorElements = ir.elements.filter { $0.kind == .resistor }

        #expect(result.status == .success)
        #expect(ir.nets.count == 10)
        #expect(ir.elements.count == 39)
        #expect(capacitorElements.count == 20)
        #expect(couplingElements.count == 9)
        #expect(resistorElements.count == 10)
        #expect(abs(ir.nets.map(\.totalGroundCapF).reduce(0, +) - 2.75e-12) < 1e-24)
        #expect(abs(ir.nets.map(\.totalCouplingCapF).reduce(0, +) - 2.25e-13) < 1e-25)
        #expect(abs(ir.nets.map(\.totalResistanceOhm).reduce(0, +) - 550.0) < 1e-9)
        #expect(abs(capacitorElements.map(\.value).reduce(0, +) - 2.75e-12) < 1e-24)
        #expect(abs(couplingElements.map(\.value).reduce(0, +) - 2.25e-13) < 1e-25)
        #expect(abs(resistorElements.map(\.value).reduce(0, +) - 550.0) < 1e-9)
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test func repeatedRunsAreDeterministicForSameInputs() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_determinism_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir.appending(path: "inputs"))
        let firstWorkspace = tempDir.appending(path: "first")
        let secondWorkspace = tempDir.appending(path: "second")
        let first = try await DefaultPEXEngine.withDefaults().run(makeMockRequest(inputs: inputs, workspace: firstWorkspace))
        let second = try await DefaultPEXEngine.withDefaults().run(makeMockRequest(inputs: inputs, workspace: secondWorkspace))
        let firstIR = try #require(first.cornerResults.first?.ir)
        let secondIR = try #require(second.cornerResults.first?.ir)

        #expect(first.status == .success)
        #expect(second.status == .success)
        #expect(first.requestHash == second.requestHash)
        #expect(firstIR == secondIR)
        #expect(canonicalArtifactGraph(first.artifacts) == canonicalArtifactGraph(second.artifacts))
    }

    @Test func defaultPEXServiceExtractAndLoadRun() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_service_test_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir)

        let service = DefaultPEXService.withDefaults()

        let tech = TechnologyIR(
            processName: "test_process",
            stack: [TechnologyLayer(name: "M1", order: 0, thickness: 0.1, material: "copper", resistivity: 1.7e-8)],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )

        let engine = DefaultPEXEngine.withDefaults()
        let request = PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(tech),
            backendSelection: .mock(),
            options: .default,
            workingDirectory: tempDir
        )

        let result = try await engine.run(request)
        #expect(result.status == .success)

        let loaded = try service.loadRun(result.runID, workspace: tempDir)
        #expect(loaded.runID == result.runID)
        #expect(loaded.status == .success)
        #expect(loaded.cornerResults.count == 1)
        #expect(loaded.cornerResults[0].ir != nil)
        #expect(loaded.artifacts.artifacts(kind: .parasiticIR, cornerID: PEXCornerID("tt")).count == 1)
        #expect(loaded.extractorRun?.request.backendID == "mock")
        #expect(loaded.extractorRun?.readiness.status == .ready)
        let lineage = try service.loadLineage(result.runID, workspace: tempDir)
        #expect(lineage.rootRunID == result.runID)
        #expect(lineage.leafRunID == result.runID)
        #expect(lineage.effectiveStatus == .success)
        #expect(lineage.effectiveCornerResults.map(\.cornerID) == [PEXCornerID("tt")])

        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: result.runID)
        let manifest = try PEXArtifactStore(workspace: workspace).loadManifest()
        let manifestCorner = try #require(manifest.corners.first { $0.cornerID == PEXCornerID("tt") })
        #expect(manifest.artifacts(kind: .rawOutput, cornerID: "tt").first?.relativePath.value == "raw/tt/tt.spef")
        #expect(manifest.artifacts(kind: .parasiticIR, cornerID: "tt").first?.relativePath.value == "ir/tt.json")
        #expect(manifest.artifacts(kind: .spefRoundTrip, cornerID: "tt").first?.relativePath.value == "spef/tt.spef")
        #expect(manifest.artifacts(kind: .spiceBackannotation, cornerID: "tt").first?.relativePath.value == "spice/tt.cir")
        #expect(manifestCorner.artifactIDs.contains("ir-tt"))
        #expect(manifestCorner.artifactIDs.contains("spef-roundtrip-tt"))
        #expect(manifestCorner.artifactIDs.contains("spice-backannotation-tt"))
    }

    @Test func defaultPEXServiceQueryNet() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_query_test_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir)

        let tech = TechnologyIR(
            processName: "test_process",
            stack: [TechnologyLayer(name: "M1", order: 0, thickness: 0.1, material: "copper", resistivity: 1.7e-8)],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )

        let engine = DefaultPEXEngine.withDefaults()
        let request = PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(tech),
            backendSelection: .mock(),
            options: .default,
            workingDirectory: tempDir
        )

        let result = try await engine.run(request)
        #expect(result.status == .success)

        let service = DefaultPEXService.withDefaults()

        guard let firstNet = result.cornerResults.first?.ir?.nets.first else {
            throw PEXError.internalInvariantViolation("No nets found in result")
        }

        let summary = try service.queryNet(
            firstNet.name,
            runID: result.runID,
            corner: PEXCornerID("tt"),
            workspace: tempDir
        )
        #expect(summary.netName == firstNet.name)
        #expect(summary.cornerID == PEXCornerID("tt"))
        #expect(summary.nodeCount == firstNet.nodes.count)
    }

    @Test func defaultPEXServiceModuleSummaryAndCornerDelta() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_module_query_test_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir)
        let engine = DefaultPEXEngine.withDefaults()
        let request = PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [
                PEXCorner(id: "tt", name: "tt", temperature: 25),
                PEXCorner(id: "hot", name: "hot", temperature: 125),
            ],
            technology: .inline(makeTestTech()),
            backendSelection: .mock(),
            options: .default,
            workingDirectory: tempDir
        )

        let result = try await engine.run(request)
        let service = DefaultPEXService.withDefaults()
        let module = try service.moduleSummary(
            InstancePath("TESTCELL"),
            runID: result.runID,
            corner: PEXCornerID("tt"),
            workspace: tempDir
        )
        #expect(module.netNames.count == 10)
        #expect(module.nodeCount == 30)
        #expect(module.totalGroundCapF > 0)

        let delta = try service.cornerDelta(
            runID: result.runID,
            baseCorner: PEXCornerID("tt"),
            targetCorner: PEXCornerID("hot"),
            workspace: tempDir
        )
        #expect(delta.netDeltas.count == 10)
        #expect(delta.totalGroundCapDeltaF > 0)
        #expect(delta.totalResistanceDeltaOhm > 0)
        #expect(delta.netDeltas.first?.targetNodeCount == 3)
    }

    @Test func moduleSummaryIncludesUnscopedRootNetsWithoutAttributingThemToChildren() throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appending(path: "pex-module-root-query-(UUID().uuidString)")
        defer { removeTemporaryItem(baseURL) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: baseURL, runID: runID)
        try workspace.createDirectories(corners: ["tt"])
        let rootNet = ParasiticNet(
            name: NetName("VDD"),
            nodes: [ParasiticNode(name: NodeName("vdd"), kind: .pin, instancePath: nil, coordinate: nil)],
            totalGroundCapF: 1e-12,
            totalCouplingCapF: 0,
            totalResistanceOhm: 1
        )
        let childNet = ParasiticNet(
            name: NetName("N1"),
            nodes: [ParasiticNode(name: NodeName("u1:n1"), kind: .pin, instancePath: InstancePath("TOP/u1"), coordinate: nil)],
            totalGroundCapF: 2e-12,
            totalCouplingCapF: 0,
            totalResistanceOhm: 2
        )
        let ir = ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: [rootNet, childNet],
            elements: [],
            metadata: ["topCell": "TOP"]
        )
        let store = PEXArtifactStore(workspace: workspace)
        let recorder = PEXArtifactRecorder(workspace: workspace)
        try store.saveIR(ir, for: "tt")
        let irRecord = try recorder.recordExistingArtifact(
            url: workspace.cornerIRURL("tt"),
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: "tt",
            id: "ir-tt"
        )
        try store.saveManifest(PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("module-root-query"),
            backendID: "mock",
            status: .success,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            corners: [PEXArtifactCorner(cornerID: "tt", status: .success, artifactIDs: [irRecord.id])],
            artifacts: [irRecord],
            warnings: []
        ))

        let service = DefaultPEXService.withDefaults()
        let root = try service.moduleSummary(InstancePath("TOP"), runID: runID, corner: "tt", workspace: baseURL)
        #expect(root.netNames == [NetName("N1"), NetName("VDD")])
        let child = try service.moduleSummary(InstancePath("TOP/u1"), runID: runID, corner: "tt", workspace: baseURL)
        #expect(child.netNames == [NetName("N1")])
    }

    @Test func profileDeclaredCornerDecksAllowNonNativeMultiCornerAdapter() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_profile_corner_test_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir)
        let ttDeck = tempDir.appending(path: "tt.magicrc")
        let ssDeck = tempDir.appending(path: "ss.magicrc")
        try Data("tt\n".utf8).write(to: ttDeck)
        try Data("ss\n".utf8).write(to: ssDeck)
        let profile = PEXProcessProfileReference(
            primaryDeckPath: ttDeck.path(percentEncoded: false),
            cornerDeckPaths: [
                "tt": ttDeck.path(percentEncoded: false),
                "ss": ssDeck.path(percentEncoded: false),
            ]
        )
        let engine = makeEngine(adapter: CornerDeckAwarePEXAdapter())
        let request = PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [PEXCorner(id: "tt"), PEXCorner(id: "ss")],
            technology: .inline(makeTestTech()),
            processProfile: profile,
            backendSelection: PEXBackendSelection(backendID: "corner-deck-aware"),
            options: .default,
            workingDirectory: tempDir
        )

        let result = try await engine.run(request)
        #expect(result.status == .success)
        #expect(result.cornerResults.map(\.cornerID) == [PEXCornerID("tt"), PEXCornerID("ss")])
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: result.runID)
        let manifest = try PEXArtifactStore(workspace: workspace).loadManifest()
        let deckArtifacts = manifest.artifacts(kind: .processProfileDeckInput)
        #expect(deckArtifacts.count == 2)
        #expect(deckArtifacts.allSatisfy { $0.status == .available && $0.sha256 != nil && $0.byteCount != nil })
        #expect(deckArtifacts.allSatisfy { $0.relativePath.value.hasPrefix("inputs/process-profile-decks/") })
    }

    @Test func loadRunDoesNotRequireIRWhenIRJSONEmissionIsDisabled() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_no_ir_test_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir)

        let options = PEXRunOptions(
            extractMode: .rc,
            includeCouplingCaps: true,
            minCapacitanceF: nil,
            minResistanceOhm: nil,
            maxParallelJobs: 1,
            emitRawArtifacts: true,
            emitIRJSON: false,
            strictValidation: false
        )
        let engine = DefaultPEXEngine.withDefaults()
        let request = PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(makeTestTech()),
            backendSelection: .mock(),
            options: options,
            workingDirectory: tempDir
        )

        let result = try await engine.run(request)
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: result.runID)
        let store = PEXArtifactStore(workspace: workspace)
        let manifest = try store.loadManifest()
        _ = try #require(manifest.corners.first { $0.cornerID == PEXCornerID("tt") })
        #expect(manifest.artifacts(kind: .parasiticIR, cornerID: "tt").first?.status == .omitted)

        let loaded = try store.loadResult(manifest: manifest)
        #expect(loaded.status == .success)
        #expect(loaded.cornerResults.first?.ir == nil)
    }

    @Test func adapterFailurePreservesPartialRawAndLogArtifacts() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_adapter_failure_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir)
        let engine = makeEngine(adapter: PartialFailurePEXAdapter())
        let request = PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(makeTestTech()),
            backendSelection: PEXBackendSelection(backendID: "partial-failure"),
            options: .default,
            workingDirectory: tempDir
        )

        let result = try await engine.run(request)
        let resolver = try PEXArtifactResolver(manifestURL: result.manifestURL)
        let manifestCorner = try #require(resolver.manifest.corners.first { $0.cornerID == PEXCornerID("tt") })
        let report = resolver.completenessReport()

        #expect(result.status == .failed)
        #expect(manifestCorner.failure?.stage == .backendExecution)
        #expect(resolver.records(kind: .rawOutput, cornerID: "tt", status: .available).count == 1)
        #expect(resolver.records(kind: .log, cornerID: "tt", status: .available).count == 1)
        #expect(report.issues.contains { $0.kind == .failedCorner && $0.cornerID == PEXCornerID("tt") })
        #expect(!report.issues.contains { $0.kind == .failedCornerWithoutEvidence })
    }

    @Test func parseFailurePreservesRawEvidenceAndMissingIRRecord() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_parse_failure_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir)
        let engine = makeEngine(adapter: UnsupportedFormatPEXAdapter())
        let request = PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(makeTestTech()),
            backendSelection: PEXBackendSelection(backendID: "unsupported-format"),
            options: .default,
            workingDirectory: tempDir
        )

        let result = try await engine.run(request)
        let resolver = try PEXArtifactResolver(manifestURL: result.manifestURL)
        let manifestCorner = try #require(resolver.manifest.corners.first { $0.cornerID == PEXCornerID("tt") })
        let irRecord = try #require(resolver.records(kind: .parasiticIR, cornerID: "tt").first)
        let report = resolver.completenessReport()

        #expect(result.status == .failed)
        #expect(manifestCorner.failure?.stage == .parsing)
        #expect(resolver.records(kind: .rawOutput, cornerID: "tt", status: .available).count == 1)
        #expect(irRecord.status == .missing)
        #expect(report.status == .incomplete)
        #expect(report.issues.contains { $0.kind == .failedCorner && $0.cornerID == PEXCornerID("tt") })
    }

    @Test func irPersistenceFailurePreservesRawEvidenceAndMissingIRRecord() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_ir_persistence_failure_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir)
        let engine = makeEngine(adapter: IRPersistenceFailurePEXAdapter())
        let request = PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(makeTestTech()),
            backendSelection: PEXBackendSelection(backendID: "ir-persistence-failure"),
            options: .default,
            workingDirectory: tempDir
        )

        let result = try await engine.run(request)
        let resolver = try PEXArtifactResolver(manifestURL: result.manifestURL)
        let manifestCorner = try #require(resolver.manifest.corners.first { $0.cornerID == PEXCornerID("tt") })
        let irRecord = try #require(resolver.records(kind: .parasiticIR, cornerID: "tt").first)
        let report = resolver.completenessReport()

        #expect(result.status == .failed)
        #expect(manifestCorner.failure?.stage == .persistence)
        #expect(resolver.records(kind: .rawOutput, cornerID: "tt", status: .available).count == 1)
        #expect(irRecord.status == .missing)
        #expect(report.status == .incomplete)
        #expect(report.issues.contains { $0.kind == .failedCorner && $0.cornerID == PEXCornerID("tt") })
        #expect(!report.issues.contains { $0.kind == .failedCornerWithoutEvidence })
    }

    // MARK: - Error Path Tests

    @Test func pipelineRejectsEmptyTopCell() async throws {
        let engine = DefaultPEXEngine.withDefaults()
        let request = PEXRunRequest(
            layoutURL: URL(filePath: "/tmp/test.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/test.cir"),
            sourceNetlistFormat: .spice,
            topCell: "",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(makeTestTech()),
            backendSelection: .mock(),
            options: .default
        )
        do {
            _ = try await engine.run(request)
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("topCell"))
        }
    }

    @Test func pipelineRejectsEmptyCorners() async throws {
        let engine = DefaultPEXEngine.withDefaults()
        let request = PEXRunRequest(
            layoutURL: URL(filePath: "/tmp/test.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/test.cir"),
            sourceNetlistFormat: .spice,
            topCell: "TOP",
            corners: [],
            technology: .inline(makeTestTech()),
            backendSelection: .mock(),
            options: .default
        )
        do {
            _ = try await engine.run(request)
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("corner"))
        }
    }

    @Test func pipelineRejectsDuplicateCornerIDs() async throws {
        let engine = DefaultPEXEngine.withDefaults()
        let request = PEXRunRequest(
            layoutURL: URL(filePath: "/tmp/test.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/test.cir"),
            sourceNetlistFormat: .spice,
            topCell: "TOP",
            corners: [PEXCorner(id: "tt"), PEXCorner(id: "tt")],
            technology: .inline(makeTestTech()),
            backendSelection: .mock(),
            options: .default
        )
        do {
            _ = try await engine.run(request)
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("duplicated"))
        }
    }

    @Test func pipelineRejectsInvalidNumericOptions() async throws {
        let engine = DefaultPEXEngine.withDefaults()
        let invalidOptions = PEXRunOptions(
            extractMode: .rc,
            includeCouplingCaps: true,
            minCapacitanceF: -1,
            minResistanceOhm: Double.nan,
            maxParallelJobs: 0,
            emitRawArtifacts: true,
            emitIRJSON: true,
            strictValidation: false
        )
        let request = PEXRunRequest(
            layoutURL: URL(filePath: "/tmp/test.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/test.cir"),
            sourceNetlistFormat: .spice,
            topCell: "TOP",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(makeTestTech()),
            backendSelection: .mock(),
            options: invalidOptions
        )
        do {
            _ = try await engine.run(request)
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("maxParallelJobs"))
        }
    }

    @Test func pipelineRejectsUnknownBackend() async throws {
        let engine = DefaultPEXEngine.withDefaults()
        let request = PEXRunRequest(
            layoutURL: URL(filePath: "/tmp/test.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/test.cir"),
            sourceNetlistFormat: .spice,
            topCell: "TOP",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(makeTestTech()),
            backendSelection: PEXBackendSelection(backendID: "nonexistent"),
            options: .default
        )
        do {
            _ = try await engine.run(request)
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .adapterUnavailable)
        }
    }

    @Test func pipelineRejectsMultiCornerRequestWhenBackendDoesNotSupportCornerSweep() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_no_corner_sweep_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir)
        let engine = makeEngine(adapter: SingleCornerReadyPEXAdapter())
        let request = PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [PEXCorner(id: "tt"), PEXCorner(id: "ss")],
            technology: .inline(makeTestTech()),
            backendSelection: PEXBackendSelection(backendID: "single-corner-ready"),
            options: .default,
            workingDirectory: tempDir
        )

        do {
            _ = try await engine.run(request)
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("does not support corner sweep"))
        }
    }

    @Test func pipelineRejectsBlockedExtractorReadinessBeforeExecution() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_blocked_readiness_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir)
        let engine = makeEngine(adapter: BlockedReadinessPEXAdapter())
        let request = PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(makeTestTech()),
            backendSelection: PEXBackendSelection(backendID: "blocked-readiness"),
            options: .default,
            workingDirectory: tempDir
        )

        do {
            _ = try await engine.run(request)
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .adapterUnavailable)
            #expect(error.message.contains("readiness is blocked"))
        }
    }


    @Test func technologyResolverRejectsMissingJSON() {
        let resolver = TechnologyResolver()
        do {
            _ = try resolver.resolve(.jsonFile(URL(filePath: "/nonexistent/path/tech.json")))
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .technologyResolutionFailed)
            #expect(error.message.contains("Failed to read"))
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test func technologyResolverRejectsInvalidJSON() throws {
        let tempFile = FileManager.default.temporaryDirectory.appending(path: "bad_tech_\(UUID().uuidString).json")
        defer { removeTemporaryItem(tempFile) }
        try Data("{ not valid json".utf8).write(to: tempFile)

        let resolver = TechnologyResolver()
        do {
            _ = try resolver.resolve(.jsonFile(tempFile))
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .technologyResolutionFailed)
            #expect(error.message.contains("Failed to decode"))
        }
    }

    @Test func queryNetRejectsUnknownNet() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_qerr_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir)

        let engine = DefaultPEXEngine.withDefaults()
        let request = PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(makeTestTech()),
            backendSelection: .mock(),
            options: .default,
            workingDirectory: tempDir
        )

        let result = try await engine.run(request)
        let service = DefaultPEXService.withDefaults()

        do {
            _ = try service.queryNet(
                NetName("NONEXISTENT_NET"),
                runID: result.runID,
                corner: PEXCornerID("tt"),
                workspace: tempDir
            )
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("NONEXISTENT_NET"))
        }
    }

    @Test func loadRunRejectsInvalidWorkspace() {
        let service = DefaultPEXService.withDefaults()
        do {
            _ = try service.loadRun(PEXRunID(), workspace: URL(filePath: "/nonexistent/workspace"))
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .persistenceFailed)
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test func serviceExtractViaLayoutSelection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_svc_ext_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }

        let techFile = tempDir.appending(path: "tech.json")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let inputs = try makeInputFiles(in: tempDir)
        let tech = makeTestTech()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(tech).write(to: techFile)

        let service = DefaultPEXService.withDefaults()
        let selection = LayoutSelection(
            layoutURL: inputs.layoutURL,
            netlistURL: inputs.netlistURL,
            topCell: "TOP",
            technologyPath: techFile
        )
        let result = try await service.extract(
            for: selection,
            corners: [PEXCorner(id: "tt")],
            backend: .mock()
        )
        #expect(result.status == .success)
        #expect(result.cornerResults.count == 1)
        #expect(result.cornerResults[0].ir != nil)
        #expect(result.extractorRun?.request.sourceNetlistFormat == .spice)
        #expect(result.extractorRun?.request.processProfile == nil)
    }

    @Test func multiCornerLoadRunPreservesAll() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_multi_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir)

        let engine = DefaultPEXEngine.withDefaults()
        let request = PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [PEXCorner(id: "tt"), PEXCorner(id: "ss"), PEXCorner(id: "ff")],
            technology: .inline(makeTestTech()),
            backendSelection: .mock(),
            options: .default,
            workingDirectory: tempDir
        )

        let result = try await engine.run(request)
        #expect(result.cornerResults.count == 3)

        let service = DefaultPEXService.withDefaults()
        let loaded = try service.loadRun(result.runID, workspace: tempDir)
        #expect(loaded.cornerResults.count == 3)
        #expect(loaded.metrics.cornerCount == 3)
        #expect(loaded.metrics.successCount == 3)
        #expect(loaded.extractorRun?.multiCorner.cornerCount == 3)
        #expect(loaded.extractorRun?.multiCorner.comparisonStatus == .comparable)

        let cornerIDs = Set(loaded.cornerResults.map(\.cornerID))
        #expect(cornerIDs.contains(PEXCornerID("tt")))
        #expect(cornerIDs.contains(PEXCornerID("ss")))
        #expect(cornerIDs.contains(PEXCornerID("ff")))
    }

    @Test func multiCornerResultsPreserveRequestedOrder() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_order_\(UUID().uuidString)")
        defer { removeTemporaryItem(tempDir) }
        let inputs = try makeInputFiles(in: tempDir)
        let engine = makeEngine(adapter: DelayedMockPEXAdapter())
        let request = PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [PEXCorner(id: "slow"), PEXCorner(id: "medium"), PEXCorner(id: "fast")],
            technology: .inline(makeTestTech()),
            backendSelection: PEXBackendSelection(backendID: "delayed-mock"),
            options: PEXRunOptions(
                extractMode: .rc,
                includeCouplingCaps: true,
                minCapacitanceF: nil,
                minResistanceOhm: nil,
                maxParallelJobs: 3,
                emitRawArtifacts: true,
                emitIRJSON: true,
                strictValidation: false
            ),
            workingDirectory: tempDir
        )

        let result = try await engine.run(request)
        let resultOrder = result.cornerResults.map(\.cornerID)
        let manifestOrder = result.artifacts.corners.map(\.cornerID)

        #expect(result.status == .success)
        #expect(resultOrder == [PEXCornerID("slow"), PEXCornerID("medium"), PEXCornerID("fast")])
        #expect(manifestOrder == resultOrder)
    }

    // MARK: - Helpers

    private func makeTestTech() -> TechnologyIR {
        TechnologyIR(
            processName: "test_process",
            stack: [TechnologyLayer(name: "M1", order: 0, thickness: 0.1, material: "copper", resistivity: 1.7e-8)],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )
    }

    private func makeEngine(adapter: any PEXAdapter) -> DefaultPEXEngine {
        let adapters = PEXAdapterRegistry(adapters: [adapter])
        let parsers = PEXParserRegistry()
        parsers.register(SPEFPEXParser())
        return DefaultPEXEngine(adapterRegistry: adapters, parserRegistry: parsers)
    }

    private func removeTemporaryItem(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
        }
    }

    private struct TestInputFiles {
        let layoutURL: URL
        let netlistURL: URL
    }

    private func makeInputFiles(in directory: URL) throws -> TestInputFiles {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layoutURL = directory.appending(path: "layout.gds")
        let netlistURL = directory.appending(path: "source.cir")
        try Data("layout".utf8).write(to: layoutURL)
        try Data(".subckt TESTCELL\n.ends\n".utf8).write(to: netlistURL)
        return TestInputFiles(layoutURL: layoutURL, netlistURL: netlistURL)
    }

    private func makeMockRequest(inputs: TestInputFiles, workspace: URL) -> PEXRunRequest {
        PEXRunRequest(
            layoutURL: inputs.layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: inputs.netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TESTCELL",
            corners: [PEXCorner(id: "tt"), PEXCorner(id: "ss")],
            technology: .inline(makeTestTech()),
            backendSelection: .mock(),
            options: .default,
            workingDirectory: workspace
        )
    }

    private struct CanonicalArtifactRecord: Hashable {
        let id: String
        let kind: PEXArtifactKind
        let stage: PEXStage
        let cornerID: PEXCornerID?
        let relativePath: String
        let sha256: String?
        let byteCount: Int?
        let status: PEXArtifactStatus
    }

    private func canonicalArtifactGraph(_ manifest: PEXArtifactManifest) -> [CanonicalArtifactRecord] {
        manifest.artifacts.map {
            let isRunSpecificReport = $0.kind == .report
            return CanonicalArtifactRecord(
                id: $0.id,
                kind: $0.kind,
                stage: $0.stage,
                cornerID: $0.cornerID,
                relativePath: $0.relativePath.value,
                sha256: isRunSpecificReport ? nil : $0.sha256,
                byteCount: isRunSpecificReport ? nil : $0.byteCount,
                status: $0.status
            )
        }.sorted { $0.id < $1.id }
    }

    // MARK: - Direct Parameter Tests

    @Test func directParameterRunRequestConstruction() {
        let options = PEXRunOptions(
            extractMode: .rc,
            includeCouplingCaps: true,
            minCapacitanceF: 1e-15,
            minResistanceOhm: 0.1,
            maxParallelJobs: 4,
            emitRawArtifacts: true,
            emitIRJSON: true,
            strictValidation: true
        )
        let request = PEXRunRequest(
            layoutURL: URL(filePath: "/tmp/layout.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/netlist.cir"),
            sourceNetlistFormat: .spice,
            topCell: "TOP",
            corners: [PEXCorner(id: "tt"), PEXCorner(id: "ss")],
            technology: .jsonFile(URL(filePath: "/tmp/tech.json")),
            backendSelection: PEXBackendSelection(backendID: "mock"),
            options: options,
            workingDirectory: URL(filePath: "/tmp/output")
        )

        #expect(request.topCell == "TOP")
        #expect(request.corners.count == 2)
        #expect(request.options.maxParallelJobs == 4)
        #expect(request.options.strictValidation == true)
        #expect(request.options.minCapacitanceF == 1e-15)
        #expect(request.options.minResistanceOhm == 0.1)
        #expect(request.backendSelection.backendID == "mock")
        #expect(request.workingDirectory != nil)
    }
}

private struct PartialFailurePEXAdapter: PEXAdapter {
    let backendID = "partial-failure"
    let capabilities = PEXBackendCapabilities(
        supportsCouplingCaps: false,
        supportsCornerSweep: false,
        supportsIncremental: false,
        supportsRCReduction: false,
        nativeOutputFormats: [.spef]
    )

    func prepare(_ context: PEXExecutionContext) async throws {
        try FileManager.default.createDirectory(at: context.rawOutputDirectory, withIntermediateDirectories: true)
    }

    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        let rawURL = context.rawOutputDirectory.appending(path: "\(context.corner.id.value).spef")
        let logURL = context.rawOutputDirectory.appending(path: "extraction.log")
        try Data("*SPEF partial".utf8).write(to: rawURL)
        try Data("backend failed".utf8).write(to: logURL)
        throw PEXAdapterExecutionFailure(
            message: "backend failed after evidence",
            stage: .backendExecution,
            cornerID: context.corner.id,
            generatedArtifacts: [
                PEXGeneratedArtifact(kind: .rawOutput, stage: .backendExecution, cornerID: context.corner.id, url: rawURL),
                PEXGeneratedArtifact(kind: .log, stage: .backendExecution, cornerID: context.corner.id, url: logURL),
            ]
        )
    }

    func cleanup(_ context: PEXExecutionContext) async {}
}

private struct DelayedMockPEXAdapter: PEXAdapter {
    let backendID = "delayed-mock"
    let capabilities = MockPEXAdapter().capabilities
    private let base = MockPEXAdapter()

    func prepare(_ context: PEXExecutionContext) async throws {
        try await base.prepare(context)
    }

    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        switch context.corner.id.value {
        case "slow":
            try await Task.sleep(nanoseconds: 120_000_000)
        case "medium":
            try await Task.sleep(nanoseconds: 60_000_000)
        default:
            break
        }
        return try await base.execute(context)
    }

    func cleanup(_ context: PEXExecutionContext) async {
        await base.cleanup(context)
    }
}

private struct SingleCornerReadyPEXAdapter: PEXAdapter, PEXAdapterReadinessProviding {
    let backendID = "single-corner-ready"
    let capabilities = PEXBackendCapabilities(
        supportsCouplingCaps: true,
        supportsCornerSweep: false,
        supportsIncremental: false,
        supportsRCReduction: false,
        nativeOutputFormats: [.spef]
    )

    func toolReadiness(processProfile: PEXProcessProfileReference?) -> PEXExtractorToolReadiness {
        PEXExtractorToolReadiness(
            backendID: backendID,
            status: .ready,
            reason: "Ready for single-corner extraction.",
            processProfile: processProfile,
            capabilities: capabilities
        )
    }

    func prepare(_ context: PEXExecutionContext) async throws {
        throw PEXError.backendExecutionFailed(
            backendID: backendID,
            cornerID: context.corner.id,
            message: "Execution should be gated before prepare."
        )
    }

    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        throw PEXError.backendExecutionFailed(
            backendID: backendID,
            cornerID: context.corner.id,
            message: "Execution should be gated before execute."
        )
    }

    func cleanup(_ context: PEXExecutionContext) async {}
}

private struct CornerDeckAwarePEXAdapter: PEXAdapter, PEXAdapterReadinessProviding {
    let backendID = "corner-deck-aware"
    let capabilities = PEXBackendCapabilities(
        supportsCouplingCaps: true,
        supportsCornerSweep: false,
        supportsIncremental: false,
        supportsRCReduction: false,
        nativeOutputFormats: [.spef]
    )
    private let base = MockPEXAdapter()

    func toolReadiness(processProfile: PEXProcessProfileReference?) -> PEXExtractorToolReadiness {
        PEXExtractorToolReadiness(
            backendID: backendID,
            status: .ready,
            reason: "Ready when each corner has a distinct profile deck.",
            processProfile: processProfile,
            capabilities: capabilities
        )
    }

    func supportsCornerSweep(
        corners: [PEXCorner],
        processProfile: PEXProcessProfileReference?
    ) -> Bool {
        guard let processProfile else { return false }
        let paths = corners.compactMap { processProfile.cornerDeckPaths[$0.id.value] }
        return paths.count == corners.count && Set(paths).count == corners.count
    }

    func prepare(_ context: PEXExecutionContext) async throws {
        try await base.prepare(context)
    }

    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        try await base.execute(context)
    }

    func cleanup(_ context: PEXExecutionContext) async {
        await base.cleanup(context)
    }
}

private struct BlockedReadinessPEXAdapter: PEXAdapter, PEXAdapterReadinessProviding {
    let backendID = "blocked-readiness"
    let capabilities = MockPEXAdapter().capabilities

    func toolReadiness(processProfile: PEXProcessProfileReference?) -> PEXExtractorToolReadiness {
        PEXExtractorToolReadiness(
            backendID: backendID,
            status: .blocked,
            reason: "Required extractor executable is missing.",
            processProfile: processProfile,
            capabilities: capabilities
        )
    }

    func prepare(_ context: PEXExecutionContext) async throws {
        throw PEXError.backendExecutionFailed(
            backendID: backendID,
            cornerID: context.corner.id,
            message: "Execution should be gated before prepare."
        )
    }

    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        throw PEXError.backendExecutionFailed(
            backendID: backendID,
            cornerID: context.corner.id,
            message: "Execution should be gated before execute."
        )
    }

    func cleanup(_ context: PEXExecutionContext) async {}
}

private struct IRPersistenceFailurePEXAdapter: PEXAdapter {
    let backendID = "ir-persistence-failure"
    let capabilities = MockPEXAdapter().capabilities
    private let base = MockPEXAdapter()

    func prepare(_ context: PEXExecutionContext) async throws {
        try await base.prepare(context)
    }

    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        let result = try await base.execute(context)
        let irDirectory = context.workingDirectory.appending(path: "ir")
        try FileManager.default.removeItem(at: irDirectory)
        try Data("not a directory".utf8).write(to: irDirectory)
        return result
    }

    func cleanup(_ context: PEXExecutionContext) async {
        await base.cleanup(context)
    }
}

private struct UnsupportedFormatPEXAdapter: PEXAdapter {
    let backendID = "unsupported-format"
    let capabilities = PEXBackendCapabilities(
        supportsCouplingCaps: false,
        supportsCornerSweep: false,
        supportsIncremental: false,
        supportsRCReduction: false,
        nativeOutputFormats: [.spef]
    )

    func prepare(_ context: PEXExecutionContext) async throws {
        try FileManager.default.createDirectory(at: context.rawOutputDirectory, withIntermediateDirectories: true)
    }

    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        let rawURL = context.rawOutputDirectory.appending(path: "\(context.corner.id.value).spef")
        try Data("not a valid spef".utf8).write(to: rawURL)
        let rawOutput = PEXRawOutput(format: .custom, fileURLs: [rawURL])
        return PEXAdapterExecutionResult(
            rawOutput: rawOutput,
            generatedArtifacts: [
                PEXGeneratedArtifact(kind: .rawOutput, stage: .backendExecution, cornerID: context.corner.id, url: rawURL),
            ]
        )
    }

    func cleanup(_ context: PEXExecutionContext) async {}
}
