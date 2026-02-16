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

        let tech = TechnologyIR(
            processName: "test_process",
            stack: [TechnologyLayer(name: "M1", order: 0, thickness: 0.1, material: "copper", resistivity: 1.7e-8)],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )

        let request = PEXRunRequest(
            layoutURL: URL(filePath: "/tmp/test.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/test.cir"),
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

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func defaultPEXServiceExtractAndLoadRun() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_service_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

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
            layoutURL: URL(filePath: "/tmp/test.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/test.cir"),
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
    }

    @Test func defaultPEXServiceQueryNet() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "pex_query_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

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
            layoutURL: URL(filePath: "/tmp/test.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/test.cir"),
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

    @Test func technologyResolverRejectsToml() {
        let resolver = TechnologyResolver()
        do {
            _ = try resolver.resolve(.tomlFile(URL(filePath: "/tmp/tech.toml")))
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .technologyResolutionFailed)
            #expect(error.message.contains("TOML"))
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test func technologyResolverRejectsDirectory() {
        let resolver = TechnologyResolver()
        do {
            _ = try resolver.resolve(.directory(URL(filePath: "/tmp/tech-pkg/")))
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .technologyResolutionFailed)
            #expect(error.message.contains("Directory"))
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
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
        defer { try? FileManager.default.removeItem(at: tempFile) }
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
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = DefaultPEXEngine.withDefaults()
        let request = PEXRunRequest(
            layoutURL: URL(filePath: "/tmp/test.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/test.cir"),
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
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let techFile = tempDir.appending(path: "tech.json")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tech = makeTestTech()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(tech).write(to: techFile)

        let service = DefaultPEXService.withDefaults()
        let selection = LayoutSelection(
            layoutURL: URL(filePath: "/tmp/test.gds"),
            netlistURL: URL(filePath: "/tmp/test.cir"),
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
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = DefaultPEXEngine.withDefaults()
        let request = PEXRunRequest(
            layoutURL: URL(filePath: "/tmp/test.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/test.cir"),
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
