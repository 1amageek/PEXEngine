import Foundation
import Testing
import CircuiteFoundation
import PEXCore
import PEXAdapters
import PEXParsers
import PEXPersistence
import PEXRuntime
import PEXTestSupport

@Suite("Fileless canonical execution contract", .timeLimit(.minutes(1)))
struct PEXCanonicalExecutionTests {
    private func withRequest<Result>(_ body: (PEXRunRequest) async throws -> Result) async throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pex-canonical-contract-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Failed to remove canonical contract fixture: \(error)") }
        }
        let layout = directory.appending(path: "fixture.gds"), source = directory.appending(path: "fixture.sp")
        try Data("contract fixture; not native geometry proof".utf8).write(to: layout)
        try Data(".subckt TOP A B\n.ends TOP\n".utf8).write(to: source)
        return try await body(PEXRunRequest(layoutURL: layout, layoutFormat: .gds, sourceNetlistURL: source,
            sourceNetlistFormat: .spice, topCell: "TOP", corners: [PEXCorner(id: "tt")],
            technology: .inline(TechnologyIR(processName: "contract", stack: [], logicalToPhysicalLayerMap: [:], vias: [],
                defaultExtractionRules: .default, backendHints: [:])), backendSelection: .init(backendID: "canonical-fixture"),
            options: .default, workingDirectory: directory))
    }
    private func engine(_ variant: CanonicalFixtureAdapter.Variant = .valid, parsers: PEXParserRegistry = PEXParserRegistry()) -> DefaultPEXEngine {
        DefaultPEXEngine(adapterRegistry: .init(adapters: [CanonicalFixtureAdapter(variant: variant)]), parserRegistry: parsers)
    }
    private func replacing(_ request: PEXRunRequest, corners: [PEXCorner]? = nil, expected: ProducerIdentity? = nil) -> PEXRunRequest {
        PEXRunRequest(layoutURL: request.layoutURL, layoutFormat: request.layoutFormat, sourceNetlistURL: request.sourceNetlistURL,
            sourceNetlistFormat: request.sourceNetlistFormat, topCell: request.topCell, corners: corners ?? request.corners,
            technology: request.technology, backendSelection: .init(backendID: request.backendSelection.backendID, expectedProducer: expected),
            options: request.options, workingDirectory: request.workingDirectory)
    }

    @Test func canonicalOutputRunsPersistsAndReloadsWithoutAParserOrRawArtifact() async throws {
        try await withRequest { request in
            let result = try await engine().run(request)
            #expect(result.status == .success && result.cornerResults.count == 1)
            #expect(result.cornerResults[0].rawOutputURLs.isEmpty)
            #expect(result.cornerResults[0].ir == CanonicalFixtureAdapter.graph(corner: "tt"))
            #expect(result.artifactManifest.artifacts(kind: .rawOutput).isEmpty)
            #expect(result.artifactManifest.artifacts(kind: .processEvidence).count == 1)
            let identity = try #require(result.artifactManifest.backendExecutions.first)
            #expect(identity.invocation.mode == .inProcess && identity.invocation.executable == nil && identity.invocation.arguments.isEmpty)
            let store = PEXArtifactStore(workspace: PEXRunWorkspace(baseURL: try #require(request.workingDirectory), runID: result.runID))
            let loaded = try store.loadResult()
            #expect(loaded.status == .success && loaded.cornerResults[0].ir == result.cornerResults[0].ir && loaded.cornerResults[0].rawOutputURLs.isEmpty)
            #expect(loaded.artifactManifest.backendExecutions == result.artifactManifest.backendExecutions)
        }
    }

    @Test func wrongCanonicalCornerRetainsIdentityAndEvidenceAsFailure() async throws {
        try await withRequest { request in
            let result = try await engine(.wrongCorner).run(request)
            #expect(result.status == .failed && result.cornerResults[0].ir == nil && result.cornerResults[0].rawOutputURLs.isEmpty)
            #expect(result.artifactManifest.corners[0].failure?.stage == .irValidation)
            #expect(result.artifactManifest.artifacts(kind: .processEvidence).count == 1 && result.artifactManifest.backendExecutions.count == 1)
            #expect(result.artifactManifest.artifacts(kind: .rawOutput).isEmpty)
        }
    }

    @Test func expectedProducerIsEnforcedForFilelessBackends() async throws {
        try await withRequest { request in
            let expected = try PEXTestExecutionIdentity.make(backendID: "canonical-fixture", version: "another-build").producer
            let result = try await engine().run(replacing(request, expected: expected))
            #expect(result.status == .failed && result.cornerResults[0].ir == nil)
            #expect(result.artifactManifest.corners[0].failure?.stage == .backendExecution)
            #expect(result.artifactManifest.backendExecutions.first?.producer != expected)
            #expect(result.artifactManifest.artifacts(kind: .processEvidence).count == 1)
        }
    }

    @Test func returnedProducerMustIdentifyTheExecutingBackend() async throws {
        try await withRequest { request in
            let result = try await engine(.wrongProducer).run(request)
            #expect(result.status == .failed && result.cornerResults[0].ir == nil)
            #expect(result.artifactManifest.corners[0].failure?.stage == .backendExecution)
            #expect(result.artifactManifest.artifacts(kind: .processEvidence).count == 1)
        }
    }

    @Test func laterArtifactFailureKeepsEarlierVerifiedEvidence() async throws {
        try await withRequest { request in
            let result = try await engine(.laterArtifactFailure).run(request)
            #expect(result.status == .failed && result.cornerResults[0].ir == nil)
            #expect(result.artifactManifest.corners[0].failure?.stage == .persistence)
            #expect(result.artifactManifest.artifacts(kind: .processEvidence).count == 1)
            #expect(result.artifactManifest.backendExecutions.count == 1 && result.artifactManifest.artifacts(kind: .rawOutput).isEmpty)
            let workspace = PEXRunWorkspace(baseURL: try #require(request.workingDirectory), runID: result.runID)
            let resolver = try PEXArtifactResolver(workspace: workspace, manifest: result.artifactManifest)
            let record = try #require(resolver.records(kind: .processEvidence, availability: .available).first)
            #expect(try Data(contentsOf: resolver.validatedURL(for: record)) == Data("{\"contractFixture\":true}".utf8))
        }
    }

    @Test(arguments: [CanonicalFixtureAdapter.Variant.mixedModes, .mixedEntryPoints])
    func multiCornerIdentityCannotMixInvocationModeOrEntryPoint(_ variant: CanonicalFixtureAdapter.Variant) async throws {
        try await withRequest { request in
            do {
                _ = try await engine(variant, parsers: PEXDefaultParsers.makeRegistry()).run(
                    replacing(request, corners: [PEXCorner(id: "tt"), PEXCorner(id: "ss")]))
                Issue.record("Mixed backend invocation identity must not publish a successful run")
            } catch let error as PEXError {
                #expect(error.kind == .backendExecutionFailed && error.message.contains("changed between corner"))
            }
        }
    }
}

// This contract fixture tests dispatch and retention, not native extraction or image measurement.
struct CanonicalFixtureAdapter: PEXExtracting {
    enum Variant: Sendable { case valid, wrongCorner, wrongProducer, mixedModes, mixedEntryPoints, laterArtifactFailure }
    let variant: Variant
    let backendID = "canonical-fixture"
    var capabilities: PEXBackendCapabilities {
        .init(supportsCouplingCaps: true, supportsCornerSweep: true, supportsIncremental: false,
              supportsRCReduction: false, nativeOutputFormats: [])
    }
    func prepare(_ context: PEXExecutionContext) async throws {}
    func cleanup(_ context: PEXExecutionContext) async {}
    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        var identity = try PEXTestExecutionIdentity.make(backendID: variant == .wrongProducer ? "different" : backendID)
        let ir = Self.graph(corner: variant == .wrongCorner ? "unexpected" : context.corner.id)
        let output: PEXBackendOutput
        if context.corner.id.value == "ss", variant == .mixedModes {
            // Deliberately inconsistent identity is a negative aggregation fixture.
            identity = try PEXBackendExecutionIdentity(producer: identity.producer, binaryDigest: identity.binaryDigest,
                invocation: .externalProcess(executable: "/negative-contract-fixture/tool"), environment: identity.environment)
            let url = context.rawOutputDirectory.appending(path: "ss.spef")
            try SPEFWriter().write(ir, to: url)
            output = .raw(.init(format: .spef, fileURLs: [url]))
        } else {
            if context.corner.id.value == "ss", variant == .mixedEntryPoints {
                identity = try PEXBackendExecutionIdentity(producer: identity.producer, binaryDigest: identity.binaryDigest,
                    invocation: .inProcess(entryPoint: "NegativeFixture.otherEntryPoint"), environment: identity.environment)
            }
            output = .canonical(ir)
        }
        let evidence = context.workingDirectory.appending(path: "contract-\(context.corner.id.value).json")
        try Data("{\"contractFixture\":true}".utf8).write(to: evidence)
        var artifacts = [PEXGeneratedArtifact(kind: .processEvidence, stage: .backendExecution, cornerID: context.corner.id,
            url: evidence, producer: identity.producer)]
        if variant == .laterArtifactFailure {
            artifacts.append(.init(kind: .processEvidence, stage: .backendExecution, cornerID: context.corner.id,
                url: context.workingDirectory.appending(path: "missing-contract-evidence.json"), producer: identity.producer))
        }
        return try PEXAdapterExecutionResult(output: output, generatedArtifacts: artifacts, executionIdentity: identity)
    }
    static func graph(corner: PEXCornerID) -> ParasiticIR {
        let net = NetName("SIGNAL"), a = NodeRef(netName: NetName("SIGNAL"), nodeName: NodeName("A")), b = NodeRef(netName: NetName("SIGNAL"), nodeName: NodeName("B"))
        return ParasiticIR(version: ParasiticIR.currentVersion, cornerID: corner, units: .canonical,
            nets: [.init(name: net, nodes: [a, b].map { .init(name: $0.nodeName, kind: .pin, instancePath: nil, coordinate: nil) },
                totalGroundCapF: 1e-15, totalCouplingCapF: 0, totalResistanceOhm: 2)],
            elements: [.init(id: "R1", kind: .resistor, nodeA: a, nodeB: b, value: 2, source: .calculated),
                .init(id: "C1", kind: .capacitor, nodeA: a, nodeB: nil, value: 1e-15, source: .calculated)], metadata: ["topCell": "TOP"])
    }
}
