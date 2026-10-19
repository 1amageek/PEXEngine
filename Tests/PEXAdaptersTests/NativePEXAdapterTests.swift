import Foundation
import CryptoKit
import Synchronization
import Testing
import CircuiteFoundation
import PEXCore
import PEXNative
import PEXPersistence
import PEXRuntime
import LayoutCore
import LayoutTech
import LayoutIO
import LayoutVerify
import SignoffToolSupport
@testable import PEXAdapters

@Suite("Actual native backend and public run behavior", .timeLimit(.minutes(1)))
struct NativePEXAdapterTests {
    @Test(arguments: [LayoutFileFormat.gds, .oasis])
    func publicSourcePortIntegerGridSurvivesStandardExportAndNativeReload(format: LayoutFileFormat) async throws {
        try await fixture(format: format) { f in
            let converter = MaskDataFormatConverter(tech: .standard())
            let source = Data("""
                VERSION 5.8 ; DESIGN TOP ; UNITS DISTANCE MICRONS 2000 ;
                PINS 1 ; - b + NET b + DIRECTION INOUT + LAYER M1 ( 0 0 ) ( 3080 680 ) + FIXED ( -120 -1260 ) N ; END PINS
                NETS 1 ; - b ( PIN b ) ; END NETS END DESIGN
                """.utf8)
            let document = try converter.importFromData(source, format: .def)
            try converter.exportDocument(document, to: f.request.layoutURL, format: format)
            let restored = try converter.importDocument(from: f.request.layoutURL, format: format)
            let pin = try #require(restored.cells.first?.pins.first)
            #expect(pin.position == .init(x: 1420.0 / 2000, y: -920.0 / 2000))
            #expect(pin.size == .init(width: 3080.0 / 2000, height: 680.0 / 2000))
            #expect(restored.cells.first?.nets.first { $0.id == pin.netID }?.name == "b")

            let layer = LayoutLayerID(name: "M1", purpose: "drawing")
            let capture = try LayoutConnectivityExtractor().captureConductors(document: restored, tech: .standard(),
                conductiveLayers: [layer], cellID: restored.topCellID)
            func coordinate(_ sourceDatabaseUnits: Int32) throws -> Int32 {
                try #require(Int32(exactly: capture.coordinateUnits.scale.databaseUnits(
                    forMicrometers: Double(sourceDatabaseUnits) / 2000)))
            }
            let minX = try coordinate(-120), maxX = try coordinate(2960)
            let minY = try coordinate(-1260), maxY = try coordinate(-580)
            let configuration = try NativePEXConfiguration(layoutTechnology: .standard(),
                layers: [.init(layerID: layer, electricalName: "M1", isConductive: true)],
                supplementalPins: [], netBindings: [.init(selector: .sourceDeclared(occurrenceIndex: 0,
                    expectedCellName: "TOP", sourceNetName: "b"), netName: .init("b"))],
                electrodeBindings: [.init(pinIndex: 0, terminal: .init(netName: .init("b"), nodeName: .init("b")),
                    faces: [.init(side: .minX, coordinate: minX, begin: minY, end: maxY)])],
                expectedCoordinateUnits: capture.coordinateUnits,
                maximumCellSpanDatabaseUnits: try coordinate(3080))
            let input = try #require(f.request.nativeInput)
            try JSONEncoder().encode(configuration).write(to: input.configurationURL)
            try Data(".subckt TOP b\n.ends TOP\n".utf8).write(to: f.request.sourceNetlistURL)

            let result = try await DefaultPEXEngine.withDefaults().run(f.request)
            #expect(result.status == .success)
            let ir = try #require(result.cornerResults.first?.ir)
            #expect(ir.nets.map(\.name) == [.init("b")])
            let expectedCapacitance = (1.54 * 0.34 * 1e-12 * 1e-4) + (2 * (1.54 + 0.34) * 1e-6 * 1e-10)
            #expect(abs(ir.nets[0].totalGroundCapF - expectedCapacitance) < 1e-28)
            let workspace = PEXRunWorkspace(baseURL: f.root, runID: result.runID)
            let resolver = try PEXArtifactResolver(workspace: workspace, manifest: result.artifactManifest)
            let record = try #require(resolver.records(kind: .processEvidence, availability: .available).first {
                $0.declaration.relativePath.stringValue.hasSuffix(NativePEXTopologyEvidence.artifactFileName)
            })
            let evidence = try JSONDecoder().decode(NativePEXTopologyEvidence.self,
                from: Data(contentsOf: resolver.validatedURL(for: record)))
            #expect(evidence.pins.count == 1 && evidence.ports.count == 1 && evidence.electrodeContacts.count == 1)
            #expect(evidence.opens.isEmpty && evidence.shortComponentIndices.isEmpty)
            #expect(evidence.coordinateUnits == capture.coordinateUnits)
            #expect(evidence.numericNodes.count == 1 && evidence.numericNodes[0].bounds == [minX, maxX, minY, maxY])
            #expect(evidence.ports[0].terminal == .init(netName: .init("b"), nodeName: .init("b")))
            #expect(evidence.electrodeContacts[0].ohms.isFinite && evidence.electrodeContacts[0].ohms > 0)
            let loaded = try PEXArtifactStore(workspace: workspace).loadResult()
            #expect(loaded.status == .success && loaded.cornerResults.first?.ir == ir)
            #expect(loaded.artifactManifest.backendExecutions == result.artifactManifest.backendExecutions)
        }
    }

    @Test(arguments: [LayoutFileFormat.gds, .oasis])
    func publicRunCalculatesAnalyticalRCAndReloadsObservedIdentity(format: LayoutFileFormat) async throws {
        try await fixture(format: format) { f in
            let adapter = NativePEXAdapter()
            let result = try await DefaultPEXEngine.withDefaults().run(f.request)
            #expect(result.status == .success && result.cornerResults[0].ir != nil)
            let ir = try #require(result.cornerResults[0].ir)
            #expect(abs(ir.elements.filter { $0.kind == .resistor }.reduce(0) { $0 + $1.value } - 0.02) < 1e-14)
            #expect(abs(ir.nets.reduce(0) { $0 + $1.totalGroundCapF } - 5e-16) < 1e-28)
            #expect(result.cornerResults[0].rawOutputURLs.isEmpty && result.artifactManifest.artifacts(kind: .rawOutput).isEmpty)
            let identity = try #require(result.artifactManifest.backendExecutions.first)
            let image = try NativePEXCodeImage.measure()
            #expect(identity.binaryDigest == image.digest && identity.producer.build == image.digest.hexadecimalValue)
            #expect(identity.invocation.mode == .inProcess && identity.producer.identifier == "pex-native")
            #expect(identity.producer.version == "3.1.0")
            let workspace = PEXRunWorkspace(baseURL: f.root, runID: result.runID)
            let resolver = try PEXArtifactResolver(workspace: workspace, manifest: result.artifactManifest)
            let record = try #require(resolver.records(kind: .processEvidence, availability: .available).first {
                $0.declaration.relativePath.stringValue.hasSuffix("native-topology.json")
            })
            let report = try JSONDecoder().decode(NativePEXTopologyEvidence.self, from: Data(contentsOf: resolver.validatedURL(for: record)))
            #expect(report.version == 3 && report.electricalContext == .geometric && report.image == image && report.executionIdentity == identity)
            #expect(try report.model.domainDigest() == f.technology.electricalModels![0].domainDigest())
            var obsolete = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
            obsolete["version"] = 2
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(NativePEXTopologyEvidence.self, from: JSONSerialization.data(withJSONObject: obsolete))
            }
            #expect(report.policy == NativePEXBackendPolicy(adapter: adapter))
            #expect(report.components.count == 1 && report.pins.count == 2 && report.numericNodes.count == 1)
            #expect(report.electrodeContacts.count == 2 && report.opens.isEmpty && report.shortComponentIndices.isEmpty)
            #expect(Set(report.numericCapacitorElementIDs + report.numericResistorElementIDs + report.electrodeContacts.map(\.elementID)) == Set(ir.elements.map(\.id)))
            let loaded = try PEXArtifactStore(workspace: workspace).loadResult()
            #expect(loaded.status == .success && loaded.cornerResults[0].ir == ir && loaded.artifactManifest.backendExecutions == result.artifactManifest.backendExecutions)
        }
    }
    @Test func physicalOpenIsRetainedWithoutInventingAConnectingResistor() async throws {
        try await fixture(open: true) { f in
            let result = try await execute(f)
            let report = try topology(result)
            #expect(report.components.count == 2 && report.opens.count == 1)
            #expect(report.opens[0].componentIndices == [0, 1] && report.shortComponentIndices.isEmpty)
            let ir: ParasiticIR
            guard case .canonical(let graph) = result.output else { Issue.record("Expected native canonical output"); return }
            ir = graph
            #expect(ir.elements.filter { $0.kind == .resistor }.count == 2)
            #expect(report.ports.map(\.componentIndex) == [0, 1])
        }
    }
    @Test(arguments: PEXSourceConnectivityPolicy.allCases)
    func publicNativeOpenCannotBecomeSameDesignSuccess(policy: PEXSourceConnectivityPolicy) async throws {
        try await fixture(open: true) { f in
            var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.request)) as? [String: Any])
            var options = try #require(encoded["options"] as? [String: Any]); options["sourceConnectivityPolicy"] = policy.rawValue
            encoded["options"] = options
            let request = try JSONDecoder().decode(PEXRunRequest.self, from: JSONSerialization.data(withJSONObject: encoded))
            let result = try await DefaultPEXEngine.withDefaults().run(request)
            #expect(result.status == .failed && result.cornerResults[0].ir == nil)
            #expect(result.artifactManifest.artifacts(kind: .parasiticIR).first?.availability == .available)
            let restored = try PEXArtifactStore(workspace: .init(baseURL: f.root, runID: result.runID)).loadResult()
            #expect(restored.status == .failed && restored.cornerResults[0].ir == nil)
        }
    }

    @Test func actualNativeRunRejectsMissingRootTerminalWithDiagnosticIR() async throws {
        try await fixture { f in
            try Data(".subckt TOP A B MISSING\n.ends TOP\n".utf8).write(to: f.request.sourceNetlistURL)
            let result = try await DefaultPEXEngine.withDefaults().run(f.request)
            #expect(result.status == .failed && result.cornerResults[0].ir == nil)
            #expect(result.artifactManifest.corners[0].failure?.message.contains("MISSING".lowercased()) == true)
            #expect(result.artifactManifest.artifacts(kind: .parasiticIR).first?.availability == .available)
        }
    }

    @Test func uncontactedRequiredTerminalRetainsRawGraphButRefusesPublicSuccess() async throws {
        try await fixture { f in
            let configuration = try #require(f.request.nativeInput).configurationURL
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: configuration)) as? [String: Any])
            var supplemental = try #require(object["supplementalPins"] as? [[String: Any]])
            var pin = try #require(supplemental[0]["pin"] as? [String: Any])
            pin["position"] = ["x": 2.0, "y": 2.0]; supplemental[0]["pin"] = pin
            object["supplementalPins"] = supplemental
            var electrodes = try #require(object["electrodeBindings"] as? [[String: Any]])
            electrodes[0]["faces"] = []; object["electrodeBindings"] = electrodes
            try JSONSerialization.data(withJSONObject: object).write(to: configuration)
            let diagnostic = try await execute(f)
            #expect(diagnostic.physicalTopology?.uncontactedTerminalCount == 1)
            #expect(diagnostic.physicalTopology?.isSatisfied == false)
            let result = try await DefaultPEXEngine.withDefaults().run(f.request)
            #expect(result.status == .failed && result.cornerResults[0].ir == nil)
            #expect(result.artifactManifest.corners[0].failure?.stage == .irValidation)
            let workspace = PEXRunWorkspace(baseURL: f.root, runID: result.runID)
            let retained = try PEXArtifactStore(workspace: workspace).loadIR(for: "tt")
            #expect(retained.nets.flatMap(\.nodes).contains { $0.name == NodeName("A") && $0.kind == .pin })
            #expect(try PEXArtifactStore(workspace: workspace).loadResult().cornerResults[0].ir == nil)
        }
    }

    @Test func actualNativeCornerSweepExecutesEachExactElectricalModel() async throws {
        try await fixture { f in
            let base = try #require(f.technology.electricalModels?.first)
            let conductor = try #require(base.conductors.first)
            let slow = PEXElectricalModel(law: base.law, coplanarScreening: base.coplanarScreening,
                processName: base.processName, cornerID: "ss", temperatureKelvin: base.temperatureKelvin,
                voltageVolts: base.voltageVolts, parameters: base.parameters, referenceNodeName: base.referenceNodeName,
                calibrationArtifacts: base.calibrationArtifacts, conductors: [.init(layerName: conductor.layerName,
                    bottomHeightMeters: conductor.bottomHeightMeters, thicknessMeters: conductor.thicknessMeters,
                    resistivityOhmMeters: conductor.resistivityOhmMeters * 2,
                    groundAreaFaradsPerSquareMeter: conductor.groundAreaFaradsPerSquareMeter * 2,
                    groundPerimeterFaradsPerMeter: conductor.groundPerimeterFaradsPerMeter * 2,
                    widthRange: conductor.widthRange, lengthRange: conductor.lengthRange)], vias: base.vias, couplings: base.couplings)
            let technology = TechnologyIR(processName: f.technology.processName, stack: f.technology.stack,
                logicalToPhysicalLayerMap: f.technology.logicalToPhysicalLayerMap, vias: f.technology.vias,
                defaultExtractionRules: f.technology.defaultExtractionRules, backendHints: f.technology.backendHints,
                electricalModels: [base, slow])
            let request = PEXRunRequest(layoutURL: f.request.layoutURL, layoutFormat: f.request.layoutFormat,
                sourceNetlistURL: f.request.sourceNetlistURL, sourceNetlistFormat: .spice, topCell: "TOP",
                corners: [.init(id: "tt"), .init(id: "ss")], technology: .inline(technology), nativeInput: f.request.nativeInput,
                backendSelection: f.request.backendSelection, options: .default, workingDirectory: f.root)
            let result = try await DefaultPEXEngine.withDefaults().run(request)
            #expect(result.status == .success)
            for (index, expected) in [0.02, 0.04].enumerated() {
                let ir = try #require(result.cornerResults[index].ir)
                #expect(ir.cornerID == request.corners[index].id)
                #expect(abs(ir.elements.filter { $0.kind == .resistor }.reduce(0) { $0 + $1.value } - expected) < 1e-14)
                #expect(abs(ir.nets.reduce(0) { $0 + $1.totalGroundCapF } - Double(index + 1) * 5e-16) < 1e-28)
            }
            #expect(result.artifactManifest.backendExecutions.count == 2)
            #expect(result.artifactManifest.backendExecutions[0].hasSameImplementation(as: result.artifactManifest.backendExecutions[1]))
            #expect(try PEXArtifactStore(workspace: .init(baseURL: f.root, runID: result.runID)).loadResult().cornerResults.map(\.ir) == result.cornerResults.map(\.ir))
        }
    }

    @Test func physicalShortRetainsBothClaimantsAndDedicatedPhysicalNodes() async throws {
        try await fixture(short: true) { f in
            let result = try await execute(f), report = try topology(result)
            #expect(report.shortComponentIndices == [0] && report.components[0].declaredNets.count == 2)
            #expect(Set(report.ports.map { $0.terminal.netName }) == Set([NetName("SIGNAL"), NetName("OTHER")]))
            #expect(report.numericNodes.allSatisfy { ![NetName("SIGNAL"), NetName("OTHER")].contains($0.reference.netName) })
            #expect(report.ports.map(\.componentIndex) == [0, 0] && report.electrodeContacts.count == 2)
        }
    }
    @Test func failedLowerBudgetKeepsImageAndTerminalEvidenceWithoutCanonicalOutput() async throws {
        try await fixture(meshLimit: 0) { f in
            let engine = DefaultPEXEngine(adapterRegistry: .init(adapters: [NativePEXAdapter()]), parserRegistry: .init())
            let result = try await engine.run(f.request)
            #expect(result.status == .failed && result.cornerResults[0].ir == nil)
            #expect(result.artifactManifest.backendExecutions.count == 1)
            #expect(result.artifactManifest.artifacts(kind: .processEvidence).count == 1)
            #expect(result.artifactManifest.artifacts(kind: .parasiticIR).isEmpty)
            #expect(result.artifactManifest.corners[0].failure?.message.contains("meshCells") == true)
        }
    }
    @Test func directInvocationRejectsCalibrationTamperMissingConfigAndMismatchedStandardBytes() async throws {
        try await fixture { f in
            let adapter = NativePEXAdapter()
            try Data("changed bytes".utf8).write(to: f.calibrationURL)
            let tampered = try await failure(adapter, context: f.context)
            #expect(tampered.message.contains("calibrationMismatch") && tampered.executionIdentity != nil)
            try f.calibrationBytes.write(to: f.calibrationURL)
            let missing = try await failure(adapter, context: f.contextReplacing(nativeInput: .some(nil)))
            #expect(missing.message.contains("missingConfiguration"))
            let wrongFormat = try await failure(adapter, context: f.contextReplacing(layoutFormat: .oas))
            #expect(wrongFormat.message.contains("declared layout format"))
            let bounded = try await failure(NativePEXAdapter(maximumLayoutBytes: 1), context: f.context)
            #expect(bounded.generatedArtifacts.count == 1 && bounded.message.contains("byte ceiling"))
        }
    }
    @Test func unsupportedModesThresholdsAndExternalOverridesFailExplicitly() async throws {
        try await fixture { f in
            let adapter = NativePEXAdapter()
            for mode in [PEXExtractMode.cOnly, .rOnly] {
                let options = PEXRunOptions(extractMode: mode, includeCouplingCaps: true, minCapacitanceF: nil,
                    minResistanceOhm: nil, maxParallelJobs: 1, emitRawArtifacts: true, emitIRJSON: true, strictValidation: true)
                #expect(try await failure(adapter, context: f.contextReplacing(options: options)).message.contains("complete RC"))
            }
            let options = PEXRunOptions(extractMode: .rc, includeCouplingCaps: false, minCapacitanceF: nil,
                minResistanceOhm: nil, maxParallelJobs: 1, emitRawArtifacts: true, emitIRJSON: true, strictValidation: true)
            #expect(try await failure(adapter, context: f.contextReplacing(options: options)).message.contains("complete RC"))
            #expect(try await failure(adapter, context: f.contextReplacing(selection: .init(backendID: "native", executablePath: "/unused"))).message.contains("overrides"))
            let expected = try ProducerIdentity(kind: .tool, identifier: "pex-native", version: "different", build: String(repeating: "0", count: 64))
            let rejected = try await failure(adapter, context: f.contextReplacing(selection: .init(backendID: "native", expectedProducer: expected)))
            #expect(rejected.executionIdentity?.producer != expected && rejected.message.contains("Requested producer"))
        }
    }
    @Test func asyncCancellationInterruptsActualCalculationAndJoinsItsMonitor() async throws {
        try await fixture(span: 5) { f in
            let calls = Mutex(0)
            let context = f.contextReplacing(check: {
                let count = calls.withLock { $0 += 1; return $0 }
                return count >= 3
            })
            let rejected = try await failure(NativePEXAdapter(cancellationPollInterval: .milliseconds(1)), context: context)
            #expect(rejected.failureKind == .cancelled && rejected.executionIdentity != nil)
            #expect(rejected.generatedArtifacts.allSatisfy { !$0.url.lastPathComponent.contains("topology") })
            let finished = calls.withLock { $0 }
            try await Task.sleep(for: .milliseconds(10))
            #expect(calls.withLock { $0 } == finished && finished >= 3)
        }
    }
    @Test func callbackErrorIsNotRoundedToCancellationOrSuccessAndMonitorEnds() async throws {
        enum CheckError: Error { case unavailable }
        try await fixture(span: 5) { f in
            let calls = Mutex(0)
            let context = f.contextReplacing(check: {
                if calls.withLock({ $0 += 1; return $0 }) >= 3 { throw CheckError.unavailable }
                return false
            })
            let rejected = try await failure(NativePEXAdapter(cancellationPollInterval: .milliseconds(1)), context: context)
            #expect(rejected.failureKind == .backendExecutionFailed && rejected.message.contains("cancellationCheckFailed"))
            let count = calls.withLock { $0 }; try await Task.sleep(for: .milliseconds(10))
            #expect(calls.withLock { $0 } == count)
        }
    }
    @Test func monitorFailureDuringSynchronousCalculationKeepsItsOriginalReason() async throws {
        enum CheckError: Error { case unavailable }
        try await fixture(span: 5) { f in
            let state = NativePEXCancellationState()
            let context = f.contextReplacing(check: {
                if state.stage == "calculation" { throw CheckError.unavailable }
                return false
            })
            do { _ = try await NativePEXAdapter(cancellationPollInterval: .milliseconds(1)).calculate(context, state: state)
                Issue.record("Monitor error must interrupt numerical work") }
            catch {
                #expect(state.monitorFailure == .cancellationCheckFailed("unavailable"))
                #expect(state.stage == "calculation")
                #expect(error as? NativePEXBackendError == .cancellationCheckFailed("unavailable"))
            }
        }
    }
    @Test func requiredEvidenceFailureCannotPublishSuccessfulCanonicalResult() async throws {
        try await fixture { f in
            let rejected = try await failure(NativePEXAdapter(maximumEvidenceBytes: 1), context: f.context)
            #expect(rejected.failureKind == .persistenceFailed && rejected.executionIdentity != nil)
            #expect(rejected.generatedArtifacts.isEmpty)
        }
    }
    @Test func requiredSPEFTopologyFailureRetainsCanonicalAndEarlierStandardEvidence() async throws {
        try await fixture(short: true) { f in
            let result = try await DefaultPEXEngine.withDefaults().run(f.request)
            #expect(result.status == .failed && result.cornerResults[0].ir == nil)
            #expect(result.artifactManifest.corners[0].failure?.stage == .persistence)
            #expect(result.artifactManifest.corners[0].failure?.message.contains("SPEF") == true)
            #expect(result.artifactManifest.artifacts(kind: .spefRoundTrip).first?.availability == .missing)
            #expect(result.artifactManifest.artifacts(kind: .spiceBackannotation).first?.availability == .available)
            #expect(result.artifactManifest.artifacts(kind: .parasiticIR).first?.availability == .available)
            #expect(result.artifactManifest.artifacts(kind: .processEvidence).count == 2)
            #expect(result.artifactManifest.backendExecutions.count == 1)
            let store = PEXArtifactStore(workspace: .init(baseURL: f.root, runID: result.runID))
            let diagnosticIR = try store.loadIR(for: "tt")
            #expect(diagnosticIR.elements.contains { $0.kind == .resistor && $0.nodeB?.netName != $0.nodeA.netName })
            let restored = try store.loadResult()
            #expect(restored.status == .failed && restored.cornerResults[0].ir == nil)
            // Manifest clock observations are encoded at ISO-8601 precision;
            // retained declarations, content identity, availability and failure remain exact.
            #expect(restored.artifactManifest.corners == result.artifactManifest.corners)
            #expect(restored.artifactManifest.backendExecutions == result.artifactManifest.backendExecutions)
            #expect(restored.artifactManifest.artifacts.map(\.declaration) == result.artifactManifest.artifacts.map(\.declaration))
            #expect(restored.artifactManifest.artifacts.map(\.payload) == result.artifactManifest.artifacts.map(\.payload))
            #expect(restored.artifactManifest.artifacts.map(\.provenance) == result.artifactManifest.artifacts.map(\.provenance))
            let completeness = try PEXArtifactResolver(manifestURL: result.manifestURL).completenessReport()
            #expect(!completeness.issues.contains { $0.kind == .duplicateArtifactID || $0.kind == .failedCornerWithoutEvidence })
        }
    }

    @Test func defaultNativeRetryUsesCapturedInputsAfterEveryOriginalIsRemoved() async throws {
        try await fixture { f in
            let engine = DefaultPEXEngine.withDefaults()
            let failed = try await engine.run(f.request, cancellationCheck: { true })
            #expect(failed.status == .failed)
            let store = PEXArtifactStore(workspace: .init(baseURL: f.root, runID: failed.runID))
            let captured = try store.loadRequest()
            try removeOriginals(f)
            let resumed = try await engine.retryFailedCorners(captured, from: try store.loadResult())
            #expect(resumed.status == .success && resumed.resumedFromRunID == failed.runID)
            #expect(resumed.requestHash == failed.requestHash)
            let ir = try #require(resumed.cornerResults.first?.ir)
            #expect(abs(ir.elements.filter { $0.kind == .resistor }.reduce(0) { $0 + $1.value } - 0.02) < 1e-14)
            #expect(resumed.artifactManifest.artifacts(kind: .spiceBackannotation).first?.availability == .available)
            #expect(resumed.artifactManifest.artifacts(kind: .spefRoundTrip).first?.availability == .available)
        }
    }

    @Test func executableCLIExtractsAndRejectsRetryFromAnotherActualImage() async throws {
        try await fixture { f in
            let executable = try cliExecutable()
            let technology = f.root.appending(path: "technology.json")
            let reference = f.root.appending(path: "native-input.json")
            try JSONEncoder().encode(f.technology).write(to: technology)
            try JSONEncoder().encode(try #require(f.request.nativeInput)).write(to: reference)
            let output = f.root.appending(path: "cli-runs")
            let runner = TimedProcessRunner(timeoutSeconds: 20, maximumOutputByteCount: 4 * 1024 * 1024, cleanupTimeoutSeconds: 5)
            let extraction = try await runner.run(executableURL: executable, arguments: ["extract", "--layout", f.request.layoutURL.path,
                "--netlist", f.request.sourceNetlistURL.path, "--top-cell", "TOP", "--technology", technology.path,
                "--native-input", reference.path, "--backend", "native", "--corner", "tt", "--out", output.path, "--json"])
            #expect(extraction.exitCode == 0, "\(extraction.standardError)\n\(extraction.standardOutput)")
            let json = try #require(try JSONSerialization.jsonObject(with: extraction.standardOutputData) as? [String: Any])
            let manifest = URL(filePath: try #require((json["manifestURL"] as? String).flatMap { URL(string: $0)?.path }))
            let resolver = try PEXArtifactResolver(manifestURL: manifest)
            #expect(resolver.manifest.backendID == "native" && resolver.manifest.status == .success)
            #expect(resolver.manifest.backendExecutions.first?.invocation.mode == .inProcess)
            let failed = try await DefaultPEXEngine.withDefaults().run(f.request, cancellationCheck: { true })
            try removeOriginals(f)
            try FileManager.default.removeItem(at: technology)
            try FileManager.default.removeItem(at: reference)
            let retainedBefore = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
                .filter { FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path) }
            let retry = try await runner.run(executableURL: executable, arguments: ["retry", "--run", failed.manifestURL.path, "--json"])
            let cliIdentity = try #require(resolver.manifest.backendExecutions.first)
            let parentIdentity = try #require(failed.artifactManifest.backendExecutions.first)
            #expect(cliIdentity.binaryDigest != parentIdentity.binaryDigest)
            #expect(retry.exitCode == 3, "\(retry.standardError)\n\(retry.standardOutput)")
            #expect(retry.standardError.contains("Retry observed a different backend implementation"))
            #expect(retry.standardOutputData.isEmpty)
            let retainedAfter = try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil)
                .filter { FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path) }
            #expect(Set(retainedAfter) == Set(retainedBefore))
            #expect(try PEXArtifactResolver(manifestURL: failed.manifestURL).manifest.status == .failed)
        }
    }

    @Test func sameExecutableRetriesCapturedInputsAfterTransientPublicationFailure() async throws {
        try await fixture(span: 10) { f in
            let executable = try cliExecutable()
            let technology = f.root.appending(path: "technology.json"), reference = f.root.appending(path: "native-input.json")
            try JSONEncoder().encode(f.technology).write(to: technology)
            try JSONEncoder().encode(try #require(f.request.nativeInput)).write(to: reference)
            let output = f.root.appending(path: "same-image-runs")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let runner = TimedProcessRunner(timeoutSeconds: 20, maximumOutputByteCount: 4 * 1024 * 1024, cleanupTimeoutSeconds: 5)
            let (failed, blockedPath) = try await withThrowingTaskGroup(of: TimedProcessResult.self) { group in
                group.addTask {
                try await runner.run(executableURL: executable, arguments: ["extract", "--layout", f.request.layoutURL.path,
                    "--netlist", f.request.sourceNetlistURL.path, "--top-cell", "TOP", "--technology", technology.path,
                    "--native-input", reference.path, "--backend", "native", "--corner", "tt", "--out", output.path, "--json"])
                }
                defer { group.cancelAll() }
            // Block one standard publication during actual calculation, without changing any semantic input.
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            var blocker: URL?
            while ContinuousClock.now < deadline, blocker == nil {
                for run in try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil) {
                    let spef = run.appending(path: "spef")
                    if FileManager.default.fileExists(atPath: spef.path) {
                        let path = spef.appending(path: "tt.spef")
                        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
                        blocker = path; break
                    }
                }
                if blocker == nil { try await Task.sleep(for: .milliseconds(2)) }
            }
            let blockedPath = try #require(blocker)
            let failed = try #require(try await group.next())
                return (failed, blockedPath)
            }
            #expect(failed.exitCode == 3)
            let json = try #require(try JSONSerialization.jsonObject(with: failed.standardOutputData) as? [String: Any])
            let manifest = try #require((json["manifestURL"] as? String).flatMap(URL.init(string:)))
            let parent = try PEXArtifactResolver(manifestURL: manifest)
            #expect(parent.manifest.status == .failed && parent.manifest.corners.first?.failure?.stage == .persistence)
            let diagnostic = try parent.loadIR(cornerID: "tt")
            #expect(parent.records(kind: .spiceBackannotation, availability: .available).count == 1)
            try FileManager.default.removeItem(at: blockedPath)
            try removeOriginals(f)
            try FileManager.default.removeItem(at: technology)
            try FileManager.default.removeItem(at: reference)
            let retried = try await runner.run(executableURL: executable, arguments: ["retry", "--run", manifest.path, "--json"])
            #expect(retried.exitCode == 0, "\(retried.standardError)\n\(retried.standardOutput)")
            let retryJSON = try #require(try JSONSerialization.jsonObject(with: retried.standardOutputData) as? [String: Any])
            let childURL = try #require((retryJSON["manifestURL"] as? String).flatMap(URL.init(string:)))
            let child = try PEXArtifactResolver(manifestURL: childURL)
            #expect(child.manifest.status == .success && child.manifest.resumedFromRunID == parent.manifest.runID)
            #expect(child.manifest.backendExecutions == parent.manifest.backendExecutions)
            #expect(try child.loadIR(cornerID: "tt") == diagnostic)
            #expect(child.records(kind: .spefRoundTrip, availability: .available).count == 1)
            if let destination = ProcessInfo.processInfo.environment["PEX_S3_EVIDENCE_ROOT"] {
                let target = URL(filePath: destination).appending(path: "same-image-cli-\(UUID())")
                try FileManager.default.copyItem(at: f.root, to: target)
            }
        }
    }

    private func removeOriginals(_ f: NativeBackendFixture) throws {
        try FileManager.default.removeItem(at: f.request.layoutURL)
        try FileManager.default.removeItem(at: f.request.sourceNetlistURL)
        try FileManager.default.removeItem(at: try #require(f.request.nativeInput).configurationURL)
        try FileManager.default.removeItem(at: f.calibrationURL)
    }

    private func cliExecutable() throws -> URL {
        // Bundle.module ties discovery to this test product's built resources.
        var directory = Bundle.module.bundleURL.deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appending(path: "pexengine")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw PEXError.invalidInput("The test product's pexengine executable is missing; build the CLI before native integration")
    }

    private func execute(_ f: NativeBackendFixture) async throws -> PEXAdapterExecutionResult {
        let adapter = NativePEXAdapter(); try await adapter.prepare(f.context); return try await adapter.execute(f.context)
    }
    private func topology(_ result: PEXAdapterExecutionResult) throws -> NativePEXTopologyEvidence {
        let artifact = try #require(result.generatedArtifacts.first { $0.url.lastPathComponent == "native-topology.json" })
        return try JSONDecoder().decode(NativePEXTopologyEvidence.self, from: Data(contentsOf: artifact.url))
    }
    private func failure(_ adapter: NativePEXAdapter, context: PEXExecutionContext) async throws -> PEXAdapterExecutionFailure {
        try await adapter.prepare(context)
        do { _ = try await adapter.execute(context); throw NativePEXBackendError.unsupportedRequest("Expected failure") }
        catch let error as PEXAdapterExecutionFailure { return error }
    }
    private func fixture(format: LayoutFileFormat = .gds, open: Bool = false, short: Bool = false, meshLimit: Int = 100_000, span: Int32 = 1000,
                         _ body: (NativeBackendFixture) async throws -> Void) async throws {
        let f = try NativeBackendFixture(format: format, open: open, short: short, meshLimit: meshLimit, span: span)
        defer { do { try FileManager.default.removeItem(at: f.root) } catch { Issue.record("Cleanup: \(error)") } }
        try await body(f)
    }
}
