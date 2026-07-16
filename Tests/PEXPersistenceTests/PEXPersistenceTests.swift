import Testing
import Foundation
@testable import PEXCore
@testable import PEXPersistence

@Suite("PEXPersistence Tests")
struct PEXPersistenceTests {
    @Test func runSummaryRejectsMissingMultiCornerProjection() {
        let data = Data("""
        {
          "runID": "run-1",
          "status": "success",
          "backendID": "mock",
          "corners": []
        }
        """.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PEXRunSummary.self, from: data)
        }
    }

    @Test func workspaceDirectoryLayout() {
        let runID = PEXRunID()
        let base = FileManager.default.temporaryDirectory
        let workspace = PEXRunWorkspace(baseURL: base, runID: runID)

        #expect(workspace.runDirectory.path(percentEncoded: false).contains(runID.description))
        #expect(workspace.manifestURL.lastPathComponent == "manifest.json")
        #expect(workspace.requestURL.path(percentEncoded: false).contains("inputs/request.json"))
        #expect(workspace.cornerRawDirectory("tt").path(percentEncoded: false).contains("raw/tt"))
        #expect(workspace.cornerSPEFRoundTripURL("tt").path(percentEncoded: false).contains("spef/tt.spef"))
    }

    @Test func irSerializerRoundTrip() throws {
        let serializer = PEXIRSerializer()
        let ir = makeTestIR()
        let data = try serializer.encode(ir)
        let decoded = try serializer.decode(from: data)
        #expect(decoded.nets.count == ir.nets.count)
        #expect(decoded.elements.count == ir.elements.count)
        #expect(decoded.cornerID == ir.cornerID)
    }

    @Test func manifestGraphCodableRequiresCurrentRecords() throws {
        let manifest = try makeManifest()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PEXArtifactManifest.self, from: data)
        #expect(decoded.version == PEXArtifactManifest.currentVersion)
        #expect(decoded.artifacts.allSatisfy { !$0.locator.location.value.hasPrefix("/") })
        #expect(decoded.artifacts.allSatisfy { $0.availability != .available || ($0.reference?.sha256 != nil && $0.reference?.byteCount != nil) })
    }

    @Test func recorderCapturesInputsInsideRunDirectory() throws {
        let tempDir = makeTemporaryDirectory("pex_capture")
        defer { removeTemporaryItem(tempDir) }

        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: PEXRunID())
        try workspace.createDirectories(corners: ["tt"])
        let inputs = try makeInputFiles(in: tempDir)

        let recorder = PEXArtifactRecorder(workspace: workspace)
        let layout = try recorder.captureInput(url: inputs.layoutURL, kind: .layoutInput)
        let netlist = try recorder.captureInput(url: inputs.netlistURL, kind: .netlistInput)
        let request = try recorder.recordRequest(makeRequest(inputs: inputs, workspace: tempDir), inputArtifacts: [layout, netlist])

        for record in [layout, netlist, request] {
            #expect(record.availability == .available)
            #expect(record.reference?.sha256 != nil)
            #expect(record.reference?.byteCount ?? 0 > 0)
            #expect(!record.locator.location.value.hasPrefix("/"))
            #expect(FileManager.default.fileExists(atPath: workspace.runDirectory.appending(path: record.locator.location.value).path(percentEncoded: false)))
        }
        #expect(layout.provenance?.sourcePath == inputs.layoutURL.path(percentEncoded: false))
    }

    @Test func storeReconstructsRunnableRequestFromCapturedInputs() throws {
        let tempDir = makeTemporaryDirectory("pex_load_request")
        defer { removeTemporaryItem(tempDir) }

        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: PEXRunID())
        try workspace.createDirectories(corners: ["tt"])
        let inputs = try makeInputFiles(in: tempDir.appending(path: "external"))
        let deckURL = tempDir.appending(path: "external/process.magicrc")
        try Data("magic deck".utf8).write(to: deckURL)
        let baseRequest = makeRequest(inputs: inputs, workspace: tempDir)
        let request = PEXRunRequest(
            layoutURL: baseRequest.layoutURL,
            layoutFormat: baseRequest.layoutFormat,
            sourceNetlistURL: baseRequest.sourceNetlistURL,
            sourceNetlistFormat: baseRequest.sourceNetlistFormat,
            topCell: baseRequest.topCell,
            corners: baseRequest.corners,
            technology: baseRequest.technology,
            processProfile: PEXProcessProfileReference(
                profileID: "test.profile",
                primaryDeckPath: deckURL.path(percentEncoded: false)
            ),
            backendSelection: baseRequest.backendSelection,
            options: baseRequest.options,
            workingDirectory: baseRequest.workingDirectory
        )
        let recorder = PEXArtifactRecorder(workspace: workspace)
        let layout = try recorder.captureInput(url: request.layoutURL, kind: .layoutInput)
        let netlist = try recorder.captureInput(url: request.sourceNetlistURL, kind: .netlistInput)
        let deck = try recorder.captureProcessProfileDeck(
            path: deckURL.path(percentEncoded: false),
            identifier: "primary"
        )
        let technology = try recorder.captureInlineTechnology(TechnologyIR(
            processName: "test",
            stack: [],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        ))
        let requestRecord = try recorder.recordRequest(
            request,
            inputArtifacts: [layout, netlist, technology, deck]
        )
        let store = PEXArtifactStore(workspace: workspace)
        try store.saveIR(makeTestIR(), for: "tt")
        let irRecord = try recorder.recordExistingArtifact(
            url: workspace.cornerIRURL("tt"),
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: "tt",
            id: "ir-tt"
        )
        try store.saveManifest(PEXArtifactManifest(
            runID: workspace.runID,
            requestHash: PEXRequestHash("load-request"),
            backendID: request.backendSelection.backendID,
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [PEXArtifactCorner(cornerID: "tt", status: .success, artifactIDs: [irRecord.id])],
            artifacts: [layout, netlist, technology, deck, requestRecord, irRecord],
            warnings: []
        ))

        let restored = try store.loadRequest()
        #expect(restored.layoutFormat == request.layoutFormat)
        #expect(restored.sourceNetlistFormat == request.sourceNetlistFormat)
        #expect(restored.topCell == request.topCell)
        #expect(restored.corners == request.corners)
        #expect(restored.backendSelection == request.backendSelection)
        #expect(restored.technology == request.technology)
        #expect(restored.processProfile?.profileID == "test.profile")
        #expect(restored.processProfile?.primaryDeckPath != deckURL.path(percentEncoded: false))
        #expect(FileManager.default.fileExists(atPath: restored.processProfile?.primaryDeckPath ?? ""))
        #expect(restored.layoutURL != request.layoutURL)
        #expect(restored.sourceNetlistURL != request.sourceNetlistURL)
        #expect(restored.workingDirectory == tempDir)
        #expect(FileManager.default.fileExists(atPath: restored.layoutURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: restored.sourceNetlistURL.path(percentEncoded: false)))
    }

    @Test func recorderCapturesProcessProfileDeckWithStableIdentifierAndFilename() throws {
        let tempDir = makeTemporaryDirectory("pex_profile_deck_capture")
        defer { removeTemporaryItem(tempDir) }

        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: PEXRunID())
        try workspace.createDirectories(corners: ["tt"])
        let deckURL = tempDir.appending(path: "external").appending(path: "sky130 tt.magicrc")
        try FileManager.default.createDirectory(at: deckURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("deck-content".utf8).write(to: deckURL)

        let record = try PEXArtifactRecorder(workspace: workspace).captureProcessProfileDeck(
            path: deckURL.path(percentEncoded: false),
            identifier: "corner/tt"
        )
        let capturedURL = workspace.runDirectory.appending(path: record.locator.location.value)

        #expect(record.id.rawValue == "input-process-profile-deck-corner-tt")
        #expect(record.matches(kind: .processProfileDeckInput))
        #expect(record.locator.location.value == "inputs/process-profile-decks/corner-tt-sky130_tt.magicrc")
        #expect(String(data: try Data(contentsOf: capturedURL), encoding: .utf8) == "deck-content")
        #expect(record.provenance?.sourcePath == deckURL.path(percentEncoded: false))
    }

    @Test func requestHashIgnoresExternalAbsoluteInputPaths() throws {
        let firstDir = makeTemporaryDirectory("pex_hash_first")
        let secondDir = makeTemporaryDirectory("pex_hash_second")
        defer { removeTemporaryItem(firstDir) }
        defer { removeTemporaryItem(secondDir) }

        let firstWorkspace = PEXRunWorkspace(baseURL: firstDir, runID: PEXRunID())
        let secondWorkspace = PEXRunWorkspace(baseURL: secondDir, runID: PEXRunID())
        try firstWorkspace.createDirectories(corners: ["tt"])
        try secondWorkspace.createDirectories(corners: ["tt"])

        let firstInputs = try makeInputFiles(in: firstDir.appending(path: "external"))
        let secondInputs = try makeInputFiles(in: secondDir.appending(path: "external"))
        let firstRecorder = PEXArtifactRecorder(workspace: firstWorkspace)
        let secondRecorder = PEXArtifactRecorder(workspace: secondWorkspace)
        let firstArtifacts: [PEXArtifactRecord] = [
            try firstRecorder.captureInput(url: firstInputs.layoutURL, kind: .layoutInput),
            try firstRecorder.captureInput(url: firstInputs.netlistURL, kind: .netlistInput),
        ]
        let secondArtifacts: [PEXArtifactRecord] = [
            try secondRecorder.captureInput(url: secondInputs.layoutURL, kind: .layoutInput),
            try secondRecorder.captureInput(url: secondInputs.netlistURL, kind: .netlistInput),
        ]

        let firstRequest = makeRequest(inputs: firstInputs, workspace: firstDir)
        let secondRequest = makeRequest(inputs: secondInputs, workspace: secondDir)
        let firstHash = try PEXRequestHash.compute(for: firstRequest, inputArtifacts: firstArtifacts)
        let secondHash = try PEXRequestHash.compute(for: secondRequest, inputArtifacts: secondArtifacts)

        #expect(firstRequest.layoutURL.path(percentEncoded: false) != secondRequest.layoutURL.path(percentEncoded: false))
        #expect(firstRequest.workingDirectory?.path(percentEncoded: false) != secondRequest.workingDirectory?.path(percentEncoded: false))
        #expect(firstHash == secondHash)
    }

    @Test func recorderDoesNotOverwriteNameCollisions() throws {
        let tempDir = makeTemporaryDirectory("pex_collision")
        defer { removeTemporaryItem(tempDir) }

        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: PEXRunID())
        try workspace.createDirectories(corners: ["tt"])
        let firstDirectory = tempDir.appending(path: "first")
        let secondDirectory = tempDir.appending(path: "second")
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let firstURL = firstDirectory.appending(path: "same.dat")
        let secondURL = secondDirectory.appending(path: "same.dat")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)

        let recorder = PEXArtifactRecorder(workspace: workspace)
        let first = try recorder.captureInput(url: firstURL, kind: .layoutInput)
        let second = try recorder.captureInput(url: secondURL, kind: .netlistInput)
        let firstCapturedURL = workspace.runDirectory.appending(path: first.locator.location.value)
        let secondCapturedURL = workspace.runDirectory.appending(path: second.locator.location.value)

        #expect(first.locator.location != second.locator.location)
        #expect(try String(contentsOf: firstCapturedURL, encoding: .utf8) == "first")
        #expect(try String(contentsOf: secondCapturedURL, encoding: .utf8) == "second")
    }

    @Test func recorderRejectsAvailableArtifactSymlinkEscapingRunDirectory() throws {
        let tempDir = makeTemporaryDirectory("pex_recorder_symlink_escape")
        defer { removeTemporaryItem(tempDir) }

        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: PEXRunID())
        try workspace.createDirectories(corners: ["tt"])
        let outsideURL = tempDir.appending(path: "outside.spef")
        try Data("*SPEF outside".utf8).write(to: outsideURL)
        let linkURL = workspace.cornerRawDirectory("tt").appending(path: "escape.spef")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)

        let recorder = PEXArtifactRecorder(workspace: workspace)
        #expect(throws: PEXError.self) {
            _ = try recorder.recordExistingArtifact(
                url: linkURL,
                kind: .rawOutput,
                stage: .backendExecution,
                cornerID: "tt"
            )
        }
    }

    @Test func recorderWritesInputSymlinkContentIntoRunArtifact() throws {
        let tempDir = makeTemporaryDirectory("pex_capture_symlink")
        defer { removeTemporaryItem(tempDir) }

        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: PEXRunID())
        try workspace.createDirectories(corners: ["tt"])
        let externalDirectory = tempDir.appending(path: "external")
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        let targetURL = externalDirectory.appending(path: "layout.gds")
        let linkURL = externalDirectory.appending(path: "layout-link.gds")
        try Data("original-layout".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        let record = try PEXArtifactRecorder(workspace: workspace).captureInput(url: linkURL, kind: .layoutInput)
        let capturedURL = workspace.runDirectory.appending(path: record.locator.location.value)
        try Data("mutated-layout".utf8).write(to: targetURL)

        #expect(record.availability == .available)
        #expect(try String(contentsOf: capturedURL, encoding: .utf8) == "original-layout")
        #expect(record.reference?.sha256 == PEXArtifactResolver.sha256(data: try Data(contentsOf: capturedURL)))
    }

    @Test func recorderDoesNotOverwriteFixedInputArtifacts() throws {
        let tempDir = makeTemporaryDirectory("pex_fixed_artifact_collision")
        defer { removeTemporaryItem(tempDir) }

        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: PEXRunID())
        try workspace.createDirectories(corners: ["tt"])
        let inputs = try makeInputFiles(in: tempDir.appending(path: "external"))
        let recorder = PEXArtifactRecorder(workspace: workspace)
        let layout = try recorder.captureInput(url: inputs.layoutURL, kind: .layoutInput)
        let netlist = try recorder.captureInput(url: inputs.netlistURL, kind: .netlistInput)

        let firstRequest = try recorder.recordRequest(makeRequest(inputs: inputs, workspace: tempDir), inputArtifacts: [layout])
        let firstRequestURL = workspace.runDirectory.appending(path: firstRequest.locator.location.value)
        let firstRequestData = try Data(contentsOf: firstRequestURL)
        let secondRequest = try recorder.recordRequest(makeRequest(inputs: inputs, workspace: tempDir), inputArtifacts: [layout, netlist])

        #expect(firstRequest.locator.location != secondRequest.locator.location)
        #expect(PEXArtifactResolver.sha256(data: try Data(contentsOf: firstRequestURL)) == firstRequest.reference?.sha256)
        #expect(try Data(contentsOf: firstRequestURL) == firstRequestData)

        let firstTechnology = try recorder.captureInlineTechnology(TechnologyIR(
            processName: "first",
            stack: [],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        ))
        let firstTechnologyURL = workspace.runDirectory.appending(path: firstTechnology.locator.location.value)
        let firstTechnologyData = try Data(contentsOf: firstTechnologyURL)
        let secondTechnology = try recorder.captureInlineTechnology(TechnologyIR(
            processName: "second",
            stack: [],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        ))

        #expect(firstTechnology.locator.location != secondTechnology.locator.location)
        #expect(PEXArtifactResolver.sha256(data: try Data(contentsOf: firstTechnologyURL)) == firstTechnology.reference?.sha256)
        #expect(try Data(contentsOf: firstTechnologyURL) == firstTechnologyData)
    }

    @Test func resolverLoadsIRThroughManifestRecord() throws {
        let tempDir = makeTemporaryDirectory("pex_resolver")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt"])
        let store = PEXArtifactStore(workspace: workspace)
        try store.saveIR(makeTestIR(), for: "tt")
        let recorder = PEXArtifactRecorder(workspace: workspace)
        let irRecord = try recorder.recordExistingArtifact(
            url: workspace.cornerIRURL("tt"),
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: "tt",
            id: "ir-tt"
        )
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("hash"),
            backendID: "mock",
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [PEXArtifactCorner(cornerID: "tt", status: .success, artifactIDs: [irRecord.id])],
            artifacts: [irRecord],
            warnings: []
        )
        try store.saveManifest(manifest)

        let resolver = try PEXArtifactResolver(workspace: workspace)
        let ir = try resolver.loadIR(cornerID: "tt")
        #expect(ir.cornerID == "tt")
        #expect(resolver.completenessReport().status == .complete)
    }

    @Test func resolverRejectsTamperedIRBeforeDecode() throws {
        let tempDir = makeTemporaryDirectory("pex_resolver_integrity")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt"])
        let store = PEXArtifactStore(workspace: workspace)
        try store.saveIR(makeTestIR(), for: "tt")
        let recorder = PEXArtifactRecorder(workspace: workspace)
        let irRecord = try recorder.recordExistingArtifact(
            url: workspace.cornerIRURL("tt"),
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: "tt",
            id: "ir-tt"
        )
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("hash"),
            backendID: "mock",
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [PEXArtifactCorner(cornerID: "tt", status: .success, artifactIDs: [irRecord.id])],
            artifacts: [irRecord],
            warnings: []
        )
        try store.saveManifest(manifest)
        try Data("tampered".utf8).write(to: workspace.cornerIRURL("tt"))

        let resolver = try PEXArtifactResolver(workspace: workspace)
        #expect(throws: PEXError.self) {
            _ = try resolver.loadIR(cornerID: "tt")
        }
        #expect(resolver.completenessReport().status == .invalid)
    }

    @Test func runSummaryBuilderLoadsMultiCornerTopNets() throws {
        let tempDir = makeTemporaryDirectory("pex_summary_builder")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt", "ss"])
        let store = PEXArtifactStore(workspace: workspace)
        try store.saveIR(makeSummaryIR(cornerID: "tt", primaryNet: "OUT"), for: "tt")
        try store.saveIR(
            makeSummaryIR(cornerID: "ss", primaryNet: "OUT", capacitanceScale: 2, resistanceScale: 3),
            for: "ss"
        )
        try Data("*SPEF \"IEEE 1481-1998\"\n".utf8).write(to: workspace.cornerSPEFRoundTripURL("tt"))
        try Data("*SPEF \"IEEE 1481-1998\"\n".utf8).write(to: workspace.cornerSPEFRoundTripURL("ss"))

        let recorder = PEXArtifactRecorder(workspace: workspace)
        let ttRecord = try recorder.recordExistingArtifact(
            url: workspace.cornerIRURL("tt"),
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: "tt",
            id: "ir-tt"
        )
        let ssRecord = try recorder.recordExistingArtifact(
            url: workspace.cornerIRURL("ss"),
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: "ss",
            id: "ir-ss"
        )
        let ttSPEFRecord = try recorder.recordExistingArtifact(
            url: workspace.cornerSPEFRoundTripURL("tt"),
            kind: .spefRoundTrip,
            stage: .persistence,
            cornerID: "tt",
            id: "spef-roundtrip-tt"
        )
        let ssSPEFRecord = try recorder.recordExistingArtifact(
            url: workspace.cornerSPEFRoundTripURL("ss"),
            kind: .spefRoundTrip,
            stage: .persistence,
            cornerID: "ss",
            id: "spef-roundtrip-ss"
        )
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("summary"),
            backendID: "mock",
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [
                PEXArtifactCorner(cornerID: "tt", status: .success, artifactIDs: [ttRecord.id, ttSPEFRecord.id]),
                PEXArtifactCorner(cornerID: "ss", status: .success, artifactIDs: [ssRecord.id, ssSPEFRecord.id]),
            ],
            artifacts: [ttRecord, ssRecord, ttSPEFRecord, ssSPEFRecord],
            warnings: []
        )
        try store.saveManifest(manifest)

        let report = try PEXRunSummaryBuilder().build(
            manifestURL: workspace.manifestURL,
            topNets: 1
        )

        #expect(report.completeness.status == .complete)
        #expect(report.summary.runID == runID.description)
        #expect(report.summary.corners.count == 2)
        #expect(report.summary.corners.first { $0.cornerID == "tt" }?.topNets.count == 1)
        #expect(report.summary.corners.first { $0.cornerID == "tt" }?.topNets.first?.name == "OUT")
        #expect(report.summary.corners.first { $0.cornerID == "tt" }?.unitSystem == "canonical")
        #expect(report.summary.corners.first { $0.cornerID == "tt" }?.parasiticIRArtifactID == "ir-tt")
        #expect(report.summary.corners.first { $0.cornerID == "tt" }?.spefRoundTripArtifactID == "spef-roundtrip-tt")
        #expect(report.summary.corners.first { $0.cornerID == "tt" }?.totalCapacitanceF ?? 0 > 0)
        #expect(report.summary.corners.first { $0.cornerID == "ss" }?.topNets.first?.name == "OUT")
        #expect(report.summary.multiCorner.cornerCount == 2)
        #expect(report.summary.multiCorner.successfulCornerCount == 2)
        #expect(report.summary.multiCorner.failedCornerCount == 0)
        #expect(report.summary.multiCorner.worstCapacitanceCornerID == "ss")
        #expect(report.summary.multiCorner.worstResistanceCornerID == "ss")
        #expect(report.summary.multiCorner.totalCapacitance.spread > 0)
        #expect(report.summary.multiCorner.totalResistance.spread > 0)
        #expect(report.summary.multiCorner.topNetSpreads.count == 1)
        #expect(report.summary.multiCorner.topNetSpreads.first?.totalCapacitance.spread ?? 0 > 0)
    }

    @Test func runSummaryBuilderTreatsMissingIRAsFailedCorner() throws {
        let tempDir = makeTemporaryDirectory("pex_summary_missing_ir")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt", "ss"])
        let store = PEXArtifactStore(workspace: workspace)
        try store.saveIR(makeSummaryIR(cornerID: "tt", primaryNet: "OUT"), for: "tt")

        let recorder = PEXArtifactRecorder(workspace: workspace)
        let ttRecord = try recorder.recordExistingArtifact(
            url: workspace.cornerIRURL("tt"),
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: "tt",
            id: "ir-tt"
        )
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("summary-missing-ir"),
            backendID: "mock",
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [
                PEXArtifactCorner(cornerID: "tt", status: .success, artifactIDs: [ttRecord.id]),
                PEXArtifactCorner(cornerID: "ss", status: .success, artifactIDs: []),
            ],
            artifacts: [ttRecord],
            warnings: []
        )
        try store.saveManifest(manifest)

        let report = try PEXRunSummaryBuilder().build(
            manifestURL: workspace.manifestURL,
            topNets: 1
        )

        let missingCorner = try #require(report.summary.corners.first { $0.cornerID == "ss" })
        #expect(missingCorner.status == "error")
        #expect(missingCorner.diagnostics.contains { $0.code == "PEX_SUMMARY_IR_MISSING" })
        #expect(report.summary.multiCorner.successfulCornerCount == 1)
        #expect(report.summary.multiCorner.failedCornerCount == 1)
        #expect(report.summary.multiCorner.failedCornerIDs == ["ss"])
        #expect(report.summary.multiCorner.totalCapacitance.observedCornerCount == 1)
        #expect(report.summary.multiCorner.totalCapacitance.minCornerID == "tt")
        #expect(report.summary.multiCorner.totalCapacitance.maxCornerID == "tt")
    }

    @Test func resolverRejectsEscapingIRPathBeforeRead() throws {
        let tempDir = makeTemporaryDirectory("pex_escape")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt"])
        let outsideDirectory = tempDir.appending(path: "outside")
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideIRURL = outsideDirectory.appending(path: "tt.json")
        let irData = try PEXIRSerializer().encode(makeTestIR())
        try irData.write(to: outsideIRURL)

        let irRecord = try makeArtifactRecord(
            id: "ir-tt",
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: "tt",
            relativePath: try ArtifactLocation(fileURL: outsideIRURL),
            sha256: PEXArtifactResolver.sha256(data: irData),
            byteCount: irData.count,
            status: .available
        )
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("hash"),
            backendID: "mock",
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [PEXArtifactCorner(cornerID: "tt", status: .success, artifactIDs: [irRecord.id])],
            artifacts: [irRecord],
            warnings: []
        )
        try PEXArtifactStore(workspace: workspace).saveManifest(manifest)

        let resolver = try PEXArtifactResolver(workspace: workspace)
        #expect(throws: PEXError.self) {
            _ = try resolver.loadIR(cornerID: "tt")
        }
        let report = resolver.completenessReport()
        #expect(report.status == .invalid)
        #expect(report.issues.contains { $0.kind == .pathEscapesRunDirectory && $0.artifactID == "ir-tt" })
    }

    @Test func completenessReportRejectsSymlinkEscapingRunDirectory() throws {
        let tempDir = makeTemporaryDirectory("pex_symlink_escape")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt"])
        let outsideURL = tempDir.appending(path: "outside.log")
        try Data("outside".utf8).write(to: outsideURL)
        let linkURL = workspace.cornerRawDirectory("tt").appending(path: "escape.log")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)
        let outsideData = try Data(contentsOf: outsideURL)

        let logRecord = try makeArtifactRecord(
            id: "log-tt",
            kind: .log,
            stage: .backendExecution,
            cornerID: "tt",
            relativePath: try ArtifactLocation(workspaceRelativePath: "raw/tt/escape.log"),
            sha256: PEXArtifactResolver.sha256(data: outsideData),
            byteCount: outsideData.count,
            status: .available
        )
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("hash"),
            backendID: "mock",
            status: .failed,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [PEXArtifactCorner(cornerID: "tt", status: .failed, artifactIDs: [logRecord.id], failure: PEXArtifactFailure(stage: .backendExecution, message: "failed"))],
            artifacts: [logRecord],
            warnings: []
        )
        try PEXArtifactStore(workspace: workspace).saveManifest(manifest)

        let report = try PEXArtifactResolver(workspace: workspace).completenessReport()
        #expect(report.status == .invalid)
        #expect(report.issues.contains { $0.kind == .pathEscapesRunDirectory && $0.artifactID == "log-tt" })
    }

    @Test func completenessReportRejectsDanglingSymlinkEscapingRunDirectory() throws {
        let tempDir = makeTemporaryDirectory("pex_dangling_symlink_escape")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt"])
        let missingOutsideURL = tempDir
            .appending(path: "outside")
            .appending(path: "missing.log")
        let linkURL = workspace.cornerRawDirectory("tt").appending(path: "dangling.log")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: missingOutsideURL)

        let logRecord = try makeArtifactRecord(
            id: "dangling-log-tt",
            kind: .log,
            stage: .backendExecution,
            cornerID: "tt",
            relativePath: try ArtifactLocation(workspaceRelativePath: "raw/tt/dangling.log"),
            sha256: String(repeating: "a", count: 64),
            byteCount: 1,
            status: .available
        )
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("hash"),
            backendID: "mock",
            status: .failed,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [
                PEXArtifactCorner(
                    cornerID: "tt",
                    status: .failed,
                    artifactIDs: [logRecord.id],
                    failure: PEXArtifactFailure(stage: .backendExecution, message: "failed")
                ),
            ],
            artifacts: [logRecord],
            warnings: []
        )
        try PEXArtifactStore(workspace: workspace).saveManifest(manifest)

        let report = try PEXArtifactResolver(workspace: workspace).completenessReport()
        #expect(report.status == .invalid)
        #expect(report.issues.contains {
            $0.kind == .pathEscapesRunDirectory && $0.artifactID == "dangling-log-tt"
        })
    }

    @Test func completenessReportDetectsHashTampering() throws {
        let tempDir = makeTemporaryDirectory("pex_hash")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt"])
        let rawURL = workspace.cornerRawDirectory("tt").appending(path: "tt.spef")
        try Data("*SPEF".utf8).write(to: rawURL)
        let recorder = PEXArtifactRecorder(workspace: workspace)
        let rawRecord = try recorder.recordExistingArtifact(url: rawURL, kind: .rawOutput, stage: .backendExecution, cornerID: "tt")
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("hash"),
            backendID: "mock",
            status: .failed,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [PEXArtifactCorner(cornerID: "tt", status: .failed, artifactIDs: [rawRecord.id], failure: PEXArtifactFailure(stage: .parsing, message: "parse failed"))],
            artifacts: [rawRecord],
            warnings: []
        )
        try PEXArtifactStore(workspace: workspace).saveManifest(manifest)
        try Data("tampered".utf8).write(to: rawURL)

        let report = try PEXArtifactResolver(workspace: workspace).completenessReport()
        #expect(report.status == .invalid)
        #expect(report.issues.contains { $0.kind == .invalidHash })
    }

    @Test func loadResultRejectsTamperedRawArtifact() throws {
        let tempDir = makeTemporaryDirectory("pex_load_tampered_raw")
        defer { removeTemporaryItem(tempDir) }
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: PEXRunID())
        try workspace.createDirectories(corners: ["tt"])
        let rawURL = workspace.cornerRawDirectory("tt").appending(path: "tt.spef")
        try Data("original".utf8).write(to: rawURL)
        let record = try PEXArtifactRecorder(workspace: workspace).recordExistingArtifact(
            url: rawURL,
            kind: .rawOutput,
            stage: .backendExecution,
            cornerID: "tt"
        )
        let manifest = PEXArtifactManifest(
            runID: workspace.runID,
            requestHash: PEXRequestHash("hash"),
            backendID: "mock",
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [PEXArtifactCorner(cornerID: "tt", status: .success, artifactIDs: [record.id])],
            artifacts: [record],
            warnings: []
        )
        let store = PEXArtifactStore(workspace: workspace)
        try store.saveManifest(manifest)
        try Data("tampered".utf8).write(to: rawURL)

        #expect(throws: PEXError.self) {
            _ = try store.loadResult()
        }
    }

    @Test func availableArtifactPayloadCarriesFoundationIntegrityMetadata() throws {
        let tempDir = makeTemporaryDirectory("pex_integrity_payload")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt"])
        let rawURL = workspace.cornerRawDirectory("tt").appending(path: "tt.spef")
        try Data("*SPEF raw".utf8).write(to: rawURL)
        let record = try PEXArtifactRecorder(workspace: workspace).recordExistingArtifact(
            url: rawURL,
            kind: .rawOutput,
            stage: .backendExecution,
            cornerID: "tt",
            id: "raw-tt"
        )
        let reference = try #require(record.reference)
        #expect(reference.digest.algorithm == .sha256)
        #expect(reference.digest.hexadecimalValue.count == 64)
        #expect(reference.byteCount == UInt64(Data("*SPEF raw".utf8).count))
    }

    @Test func completenessReportRejectsDuplicateArtifactIDs() throws {
        let tempDir = makeTemporaryDirectory("pex_duplicate_ids")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt"])
        let rawURL = workspace.cornerRawDirectory("tt").appending(path: "tt.spef")
        try Data("*SPEF".utf8).write(to: rawURL)
        let rawData = try Data(contentsOf: rawURL)
        let first = try makeArtifactRecord(
            id: "raw-duplicate",
            kind: .rawOutput,
            stage: .backendExecution,
            cornerID: "tt",
            relativePath: try ArtifactLocation(workspaceRelativePath: "raw/tt/tt.spef"),
            sha256: PEXArtifactResolver.sha256(data: rawData),
            byteCount: rawData.count,
            status: .available
        )
        let second = try makeArtifactRecord(
            id: "raw-duplicate",
            kind: .log,
            stage: .backendExecution,
            cornerID: "tt",
            relativePath: try ArtifactLocation(workspaceRelativePath: "raw/tt/tt.spef"),
            sha256: PEXArtifactResolver.sha256(data: rawData),
            byteCount: rawData.count,
            status: .available
        )
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("hash"),
            backendID: "mock",
            status: .failed,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [PEXArtifactCorner(cornerID: "tt", status: .failed, artifactIDs: [first.id], failure: PEXArtifactFailure(stage: .backendExecution, message: "failed"))],
            artifacts: [first, second],
            warnings: []
        )
        try PEXArtifactStore(workspace: workspace).saveManifest(manifest)

        let report = try PEXArtifactResolver(workspace: workspace).completenessReport()
        #expect(report.status == .invalid)
        #expect(report.issues.contains { $0.kind == .duplicateArtifactID && $0.artifactID == "raw-duplicate" })
    }

    @Test func completenessReportRejectsCornerArtifactGraphGaps() throws {
        let tempDir = makeTemporaryDirectory("pex_graph_gap")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt"])
        let store = PEXArtifactStore(workspace: workspace)
        try store.saveIR(makeTestIR(), for: "tt")
        let recorder = PEXArtifactRecorder(workspace: workspace)
        let irRecord = try recorder.recordExistingArtifact(
            url: workspace.cornerIRURL("tt"),
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: "tt",
            id: "ir-tt"
        )
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("hash"),
            backendID: "mock",
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [PEXArtifactCorner(cornerID: "tt", status: .success, artifactIDs: [])],
            artifacts: [irRecord],
            warnings: []
        )
        try store.saveManifest(manifest)

        let report = try PEXArtifactResolver(workspace: workspace).completenessReport()
        #expect(report.status == .invalid)
        #expect(report.issues.contains { $0.kind == .missingCornerArtifactReference && $0.artifactID == "ir-tt" })
    }

    @Test func completenessReportRequiresStructuredFailureForFailedCorner() throws {
        let tempDir = makeTemporaryDirectory("pex_missing_failure")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt"])
        let rawURL = workspace.cornerRawDirectory("tt").appending(path: "tt.spef")
        try Data("*SPEF partial".utf8).write(to: rawURL)
        let recorder = PEXArtifactRecorder(workspace: workspace)
        let rawRecord = try recorder.recordExistingArtifact(url: rawURL, kind: .rawOutput, stage: .backendExecution, cornerID: "tt")
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("hash"),
            backendID: "mock",
            status: .failed,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [PEXArtifactCorner(cornerID: "tt", status: .failed, artifactIDs: [rawRecord.id])],
            artifacts: [rawRecord],
            warnings: []
        )
        try PEXArtifactStore(workspace: workspace).saveManifest(manifest)

        let report = try PEXArtifactResolver(workspace: workspace).completenessReport()
        #expect(report.status == .incomplete)
        #expect(report.issues.contains { $0.kind == .missingFailure && $0.cornerID == "tt" })
    }

    @Test func completenessReportRequiresEvidenceEvenWhenFailedCornerHasNoStructuredFailure() throws {
        let tempDir = makeTemporaryDirectory("pex_failed_no_evidence")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt"])
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("hash"),
            backendID: "mock",
            status: .failed,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [PEXArtifactCorner(cornerID: "tt", status: .failed, artifactIDs: [])],
            artifacts: [],
            warnings: []
        )
        try PEXArtifactStore(workspace: workspace).saveManifest(manifest)

        let report = try PEXArtifactResolver(workspace: workspace).completenessReport()
        #expect(report.status == .incomplete)
        #expect(report.issues.contains { $0.kind == .missingFailure && $0.cornerID == "tt" })
        #expect(report.issues.contains { $0.kind == .failedCornerWithoutEvidence && $0.cornerID == "tt" })
    }

    @Test func storeLoadResultPreservesFailureEvidence() throws {
        let tempDir = makeTemporaryDirectory("pex_load")
        defer { removeTemporaryItem(tempDir) }

        let runID = PEXRunID()
        let workspace = PEXRunWorkspace(baseURL: tempDir, runID: runID)
        try workspace.createDirectories(corners: ["tt", "ss"])
        let store = PEXArtifactStore(workspace: workspace)
        try store.saveIR(makeTestIR(), for: "tt")
        let rawURL = workspace.cornerRawDirectory("ss").appending(path: "ss.spef")
        try Data("*SPEF partial".utf8).write(to: rawURL)
        let recorder = PEXArtifactRecorder(workspace: workspace)
        let irRecord = try recorder.recordExistingArtifact(url: workspace.cornerIRURL("tt"), kind: .parasiticIR, stage: .persistence, cornerID: "tt", id: "ir-tt")
        let rawRecord = try recorder.recordExistingArtifact(url: rawURL, kind: .rawOutput, stage: .backendExecution, cornerID: "ss")
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: PEXRequestHash("hash"),
            backendID: "mock",
            status: .partialSuccess,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [
                PEXArtifactCorner(cornerID: "tt", status: .success, artifactIDs: [irRecord.id]),
                PEXArtifactCorner(cornerID: "ss", status: .failed, artifactIDs: [rawRecord.id], failure: PEXArtifactFailure(stage: .parsing, message: "parse failed")),
            ],
            artifacts: [irRecord, rawRecord],
            warnings: [PEXWarning(stage: .parsing, cornerID: "ss", message: "parse failed")]
        )
        try store.saveManifest(manifest)

        let result = try store.loadResult()
        #expect(result.status == .partialSuccess)
        #expect(result.cornerResults.first { $0.cornerID == "tt" }?.ir != nil)
        #expect(result.cornerResults.first { $0.cornerID == "ss" }?.rawOutputURLs == [rawURL])
    }

    @Test func reportGeneration() throws {
        let result = try makeTestResult()
        let generator = PEXReportGenerator()
        let report = generator.generateSummary(result: result)
        #expect(report.contains("PEX Extraction Summary"))
        #expect(report.contains("success"))
    }

    private func makeManifest() throws -> PEXArtifactManifest {
        let path = try ArtifactLocation(workspaceRelativePath: "raw/tt/tt.spef")
        let record = try makeArtifactRecord(
            id: "raw-tt",
            kind: .rawOutput,
            stage: .backendExecution,
            cornerID: "tt",
            relativePath: path,
            sha256: String(repeating: "a", count: 64),
            byteCount: 5,
            status: .available
        )
        return PEXArtifactManifest(
            runID: PEXRunID(),
            requestHash: PEXRequestHash("abc123"),
            backendID: "mock",
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [PEXArtifactCorner(cornerID: "tt", status: .success, artifactIDs: [record.id])],
            artifacts: [record],
            warnings: []
        )
    }

    private func makeTestIR() -> ParasiticIR {
        ParasiticIR(
            version: "1.0",
            cornerID: "tt",
            units: .canonical,
            nets: [ParasiticNet(name: NetName("n"), nodes: [], totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0)],
            elements: [],
            metadata: [:]
        )
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

    private func makeTestResult() throws -> PEXRunResult {
        let record = try makeArtifactRecord(
            id: "raw-tt",
            kind: .rawOutput,
            stage: .backendExecution,
            cornerID: "tt",
            relativePath: try ArtifactLocation(workspaceRelativePath: "raw/tt/tt.spef"),
            sha256: String(repeating: "a", count: 64),
            byteCount: 5,
            status: .available
        )
        let manifest = PEXArtifactManifest(
            runID: PEXRunID(),
            requestHash: PEXRequestHash("hash"),
            backendID: "mock",
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            corners: [PEXArtifactCorner(cornerID: "tt", status: .success, artifactIDs: [record.id])],
            artifacts: [record],
            warnings: []
        )
        return PEXRunResult(
            runID: manifest.runID,
            requestHash: manifest.requestHash,
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            cornerResults: [
                PEXCornerResult(
                    cornerID: "tt",
                    status: .success,
                    ir: makeTestIR(),
                    metrics: PEXCornerMetrics(durationSeconds: 1.0, netCount: 1, elementCount: 0)
                )
            ],
            warnings: [],
            artifacts: manifest,
            manifestURL: URL(filePath: "/tmp/manifest.json"),
            metrics: PEXRunMetrics(totalDurationSeconds: 1.0, cornerCount: 1, successCount: 1, failureCount: 0)
        )
    }
}

private struct TestInputs {
    let layoutURL: URL
    let netlistURL: URL
}

private enum ArtifactRecordFixtureError: Error {
    case availableArtifactRequiresIntegrity
    case unsupportedAvailability
}

private func makeArtifactRecord(
    id: String,
    kind: PEXArtifactKind,
    stage: PEXStage,
    cornerID: PEXCornerID? = nil,
    relativePath: ArtifactLocation,
    sha256: String? = nil,
    byteCount: Int? = nil,
    createdAt: Date = Date(),
    status: PEXArtifactAvailability,
    provenance: PEXArtifactProvenance? = nil
) throws -> PEXArtifactRecord {
    guard status == .available else {
        throw ArtifactRecordFixtureError.unsupportedAvailability
    }
    guard let sha256, let byteCount else {
        throw ArtifactRecordFixtureError.availableArtifactRequiresIntegrity
    }
    let format: ArtifactFormat = switch relativePath.value.split(separator: ".").last?.lowercased() {
    case "spef": .spef
    case "log", "txt": .text
    default: .json
    }
    let reference = ArtifactReference(
        id: try ArtifactID(rawValue: id),
        locator: ArtifactLocator(
            location: relativePath,
            role: .output,
            kind: try ArtifactKind(rawValue: kind.foundationRawValue),
            format: format
        ),
        digest: try ContentDigest(algorithm: .sha256, hexadecimalValue: sha256),
        byteCount: UInt64(byteCount)
    )
    return PEXArtifactRecord(
        payload: .available(reference),
        stage: stage,
        cornerID: cornerID,
        createdAt: createdAt,
        provenance: provenance
    )
}

private func makeInputFiles(in directory: URL) throws -> TestInputs {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let layoutURL = directory.appending(path: "layout.gds")
    let netlistURL = directory.appending(path: "source.cir")
    try Data("layout".utf8).write(to: layoutURL)
    try Data(".subckt TOP\n.ends\n".utf8).write(to: netlistURL)
    return TestInputs(layoutURL: layoutURL, netlistURL: netlistURL)
}

private func makeRequest(inputs: TestInputs, workspace: URL) -> PEXRunRequest {
    PEXRunRequest(
        layoutURL: inputs.layoutURL,
        layoutFormat: .gds,
        sourceNetlistURL: inputs.netlistURL,
        sourceNetlistFormat: .spice,
        topCell: "TOP",
        corners: [PEXCorner(id: "tt")],
        technology: .inline(TechnologyIR(processName: "test", stack: [], logicalToPhysicalLayerMap: [:], vias: [], defaultExtractionRules: .default, backendHints: [:])),
        backendSelection: .mock(),
        options: .default,
        workingDirectory: workspace
    )
}

private func makeTemporaryDirectory(_ prefix: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "\(prefix)_\(UUID().uuidString)")
}

private func removeTemporaryItem(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
    }
}
