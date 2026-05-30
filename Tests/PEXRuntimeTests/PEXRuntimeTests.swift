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

        for cr in result.cornerResults {
            #expect(cr.status == .success)
            #expect(cr.ir != nil)
            #expect(cr.metrics.netCount > 0)
            #expect(cr.metrics.elementCount > 0)
            // Warnings field should exist (may be empty if validation passed cleanly)
            _ = cr.warnings  // Confirms field is accessible
        }

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

        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: result.runID)
        let manifest = try PEXArtifactStore(workspace: workspace).loadManifest()
        let manifestCorner = try #require(manifest.corners.first { $0.cornerID == PEXCornerID("tt") })
        #expect(manifest.artifacts(kind: .rawOutput, cornerID: "tt").first?.relativePath.value == "raw/tt/tt.spef")
        #expect(manifest.artifacts(kind: .parasiticIR, cornerID: "tt").first?.relativePath.value == "ir/tt.json")
        #expect(manifestCorner.artifactIDs.contains("ir-tt"))
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
