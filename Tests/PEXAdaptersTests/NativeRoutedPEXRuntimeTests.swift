import Foundation
import CryptoKit
import Synchronization
import Testing
import CircuiteFoundation
import PEXCore
import PEXNative
import PEXParsers
import PEXPersistence
import PEXRuntime
import SignoffToolSupport
@testable import PEXAdapters

@Suite("Actual routed Native execution and retained standard artifacts", .timeLimit(.minutes(1)))
struct NativeRoutedPEXRuntimeTests {
    @Test func publicAllCornerCalculationRetainsRawInputsResultsAndSPEFPinIdentity() async throws {
        let f = try RoutedPreparationFixture(viaOnly: true, allCorners: true)
        defer { cleanup(f) }
        let result = try await DefaultPEXEngine.withDefaults().run(f.request())
        #expect(result.status == .success)
        #expect(Set(result.cornerResults.map(\.cornerID)) == Set(["nominal", "min", "max"]))
        let resolver = try PEXArtifactResolver(manifestURL: result.manifestURL)
        for corner in result.cornerResults {
            let ir = try #require(corner.ir)
            #expect(ir.elements.contains { $0.kind == .resistor && $0.value > 0 })
            #expect(ir.elements.contains { $0.kind == .capacitor && $0.value > 0 })
            let rawInput = try evidence(NativeRoutedPEXInput.self, file: NativeRoutedPEXExecutionEvidence.inputFileName,
                corner: corner.cornerID, resolver: resolver)
            let rawResult = try evidence(NativeRoutedPEXResult.self, file: NativeRoutedPEXExecutionEvidence.resultFileName,
                corner: corner.cornerID, resolver: resolver)
            let source = try evidence(NativeRoutedPEXExecutionEvidence.self, file: NativeRoutedPEXExecutionEvidence.sourceFileName,
                corner: corner.cornerID, resolver: resolver)
            #expect(rawInput.defArtifactID == f.def.id && rawResult.ir == ir)
            #expect(rawResult.selection == source.model.selection)
            #expect(source.sourceJoin.sourceNetlistArtifactID == f.netlist.id && source.sourceJoin.instanceCount == 1)
            #expect(source.requestedCornerIDs == ["nominal", "min", "max"])
            #expect(source.executionIdentity.producer.version == "4.0.0")
            #expect(source.version == 2 && source.algorithm == .unionSheetAreaBoundaryV1)
            #expect(source.maximumCellSpanDatabaseUnits == f.configuration.maximumCellSpanDatabaseUnits)
            #expect(source.groundCapacitanceModel.cornerID == corner.cornerID)
            #expect(source.groundCapacitanceModel.selection == source.model.selection)
            let captured = try PEXArtifactStore(workspace: .init(baseURL: f.root, runID: result.runID)).loadRequest()
            let context = try replayContext(captured, corner: corner.cornerID, raw: f.root.appending(path: "replay-" + corner.cornerID.value))
            let prepared = try DefaultNativeRoutedPEXInputPreparer().prepare(context: context,
                requiredCornerIDs: captured.corners.map(\.id), isCancelled: { false })
            #expect(source.executionIdentity.environment.environmentDigest == (try NativePEXAdapter.routedEnvironmentDigest(prepared)))
            let currentImage = try NativePEXCodeImage.measure()
            let expectedIdentity = try NativePEXAdapter().executionIdentity(image: currentImage, kind: .routedOpenRCXV1, prepared: prepared)
            try source.requireBinding(to: prepared, context: context, policy: NativePEXBackendPolicy(adapter: NativePEXAdapter()),
                image: currentImage, identity: expectedIdentity)
            let record = try #require(resolver.records(kind: .spefRoundTrip, cornerID: corner.cornerID, availability: .available).first)
            let url = try resolver.validatedURL(for: record)
            let text = try String(contentsOf: url, encoding: .utf8)
            var lexer = SPEFLexer(source: text)
            let tree = try SPEFParser().parse(tokens: lexer.tokenize())
            #expect(tree.nets.flatMap(\.connections).filter { $0.type == .instancePin }.count == 1)
            let replay = try SPEFPEXParser().parse(.init(format: .spef, fileURLs: [url]), context: .init(
                cornerID: corner.cornerID, runID: result.runID, topCell: "top", technology: nil, options: .default))
            #expect(Set(replay.nets.flatMap(\.nodes)) == Set(ir.nets.flatMap(\.nodes)))
            #expect(replay.elements.count == ir.elements.count)
            var remaining = replay.elements
            for original in ir.elements {
                // Standard element ordinals are format-local. Preserve every operator
                // by kind, exact scoped endpoints and multiplicity, not its opaque ID.
                // The twelve-digit decimal writer has a separate representation bound.
                let decimalQuantum = original.value == 0 ? 0 : pow(10, floor(log10(abs(original.value))) - 11)
                let index = try #require(remaining.firstIndex { actual in
                    actual.kind == original.kind && actual.nodeA == original.nodeA && actual.nodeB == original.nodeB
                        && abs(actual.value - original.value) <= decimalQuantum / 2
                            + 8 * max(actual.value.ulp, original.value.ulp)
                })
                remaining.remove(at: index)
            }
            #expect(remaining.isEmpty)
        }
        let store = PEXArtifactStore(workspace: .init(baseURL: f.root, runID: result.runID))
        let loaded = try store.loadResult()
        #expect(loaded.cornerResults.map(\.ir) == result.cornerResults.map(\.ir))
        #expect(try store.loadRequest().sourceNetlistFormat == .verilog)
    }

    @Test func actualRewiredForeignAndIncompleteStructuralSourceCannotPassNameCoverage() throws {
        let original = "module \\top (\\input ); input \\input ; wire \\signal ; assign \\signal = \\input ; \\CELL \\U2 (.\\A (\\signal )); endmodule\n"
        for changed in [
            original.replacingOccurrences(of: "wire \\signal ;", with: "wire \\signal ; wire \\other ;")
                .replacingOccurrences(of: ".\\A (\\signal )", with: ".\\A (\\other )"),
            original.replacingOccurrences(of: "\\CELL \\U2", with: "\\FOREIGN \\U2"),
            original.replacingOccurrences(of: ".\\A (\\signal )", with: ".\\MISSING (\\signal )")
        ] {
            let f = try RoutedPreparationFixture(netlistOverride: changed)
            defer { cleanup(f) }
            do {
                _ = try DefaultNativeRoutedPEXInputPreparer().prepare(context: f.context(), requiredCornerIDs: ["nominal"])
                Issue.record("A structurally different source passed exact DEF joining")
            } catch let error as NativeRoutedPEXPreparationError {
                guard case .sourceMismatch = error else { Issue.record("Wrong source refusal: \(error)"); continue }
            } catch {
                Issue.record("Unexpected fixture or preparation failure: \(error)")
            }
        }
    }

    @Test func decoderLogicalStorageCancellationAndCumulativeHostBudgetRemainExplicit() throws {
        let f = try RoutedPreparationFixture()
        defer { cleanup(f) }
        let bytes = try Data(contentsOf: f.netlistURL)
        let preparer = DefaultNativeRoutedPEXInputPreparer()
        let tiny = NativeRoutedPEXPreparationLimits(maximumSourceBytes: 16000000, maximumTotalSourceBytes: 64000000,
            maximumRecords: 100000, maximumStringBytes: 1000000, maximumWorkVisits: 100000000,
            maximumNetlistManagedStorageBytes: 1, maximumNetlistAllocationBytes: 128000000)
        var bounded = NativeRoutedPEXPreparationBudget(limits: tiny)
        #expect(throws: NativeRoutedPEXPreparationError.limitExceeded("netlistManagedStorageBytes")) {
            _ = try preparer.decodeSource(bytes, top: "top", limits: tiny, budget: &bounded, isCancelled: { false })
        }
        let polling = Mutex(0)
        var cancelled = NativeRoutedPEXPreparationBudget(limits: f.configuration.preparationLimits)
        #expect(throws: NativeRoutedPEXPreparationError.cancelled) {
            _ = try preparer.decodeSource(bytes, top: "top", limits: f.configuration.preparationLimits,
                budget: &cancelled, isCancelled: {
                    polling.withLock { count in count += 1; return count >= 3 }
                })
        }
        #expect(polling.withLock { $0 } >= 3)
        var cumulative = NativeRoutedPEXPreparationBudget(limits: f.configuration.preparationLimits)
        let before = cumulative.remainingWorkVisits
        _ = try preparer.decodeSource(bytes, top: "top", limits: f.configuration.preparationLimits,
            budget: &cumulative, isCancelled: { false })
        #expect(cumulative.remainingWorkVisits < before)
        try cumulative.visit(cumulative.remainingWorkVisits)
        #expect(throws: NativeRoutedPEXPreparationError.limitExceeded("workVisits")) {
            _ = try preparer.decodeSource(bytes, top: "top", limits: f.configuration.preparationLimits,
                budget: &cumulative, isCancelled: { false })
        }
    }

    @Test func cancelledRunRetriesCapturedVerilogSourcesAfterOriginalDeletionAndRejectsTamper() async throws {
        let f = try RoutedPreparationFixture()
        defer { cleanup(f) }
        let engine = DefaultPEXEngine.withDefaults()
        let failed = try await engine.run(f.request(), cancellationCheck: { true })
        #expect(failed.status == .failed)
        let store = PEXArtifactStore(workspace: .init(baseURL: f.root, runID: failed.runID))
        let captured = try store.loadRequest()
        #expect(captured.nativeInput?.configurationKind == .routedOpenRCXV1 && captured.sourceNetlistFormat == .verilog)
        try f.removeOriginals()
        let resumed = try await engine.retryFailedCorners(captured, from: store.loadResult())
        #expect(resumed.status == .success && resumed.requestHash == failed.requestHash)
        #expect(resumed.cornerResults.first?.ir != nil)
        let child = PEXArtifactStore(workspace: .init(baseURL: f.root, runID: resumed.runID))
        let childRequest = try child.loadRequest()
        let input = try #require(childRequest.nativeInput?.calibrations.first)
        try Data("tampered retained source".utf8).write(to: input.url)
        #expect(throws: PEXError.self) { _ = try child.loadRequest() }
    }

    @Test func executableCLIUsesExplicitVerilogAndReloadsActualRoutedArtifacts() async throws {
        let f = try RoutedPreparationFixture(allCorners: true)
        defer { cleanup(f) }
        let technology = f.root.appending(path: "technology.json"), reference = f.root.appending(path: "reference.json")
        try JSONEncoder().encode(f.context().technology).write(to: technology)
        try JSONEncoder().encode(try #require(f.context().nativeInput)).write(to: reference)
        let runner = TimedProcessRunner(timeoutSeconds: 30, maximumOutputByteCount: 4 * 1024 * 1024, cleanupTimeoutSeconds: 5)
        let output = try await runner.run(executableURL: cliExecutable(), arguments: ["extract", "--layout", f.defURL.path,
            "--netlist", f.netlistURL.path, "--source-netlist-format", "verilog", "--top-cell", "top",
            "--technology", technology.path, "--native-input", reference.path, "--backend", "native",
            "--corner", "nominal", "--corner", "min", "--corner", "max", "--out", f.root.appending(path: "cli-runs").path, "--json"])
        #expect(output.exitCode == 0, "\(output.standardError)\n\(output.standardOutput)")
        let json = try #require(try JSONSerialization.jsonObject(with: output.standardOutputData) as? [String: Any])
        let manifest = try #require((json["manifestURL"] as? String).flatMap(URL.init(string:)))
        let resolver = try PEXArtifactResolver(manifestURL: manifest)
        #expect(resolver.manifest.status == .success && resolver.manifest.corners.count == 3)
        try f.removeOriginals()
        let workspace = PEXRunWorkspace(baseURL: manifest.deletingLastPathComponent().deletingLastPathComponent(), runID: resolver.manifest.runID)
        let store = PEXArtifactStore(workspace: workspace)
        #expect(try store.loadRequest().sourceNetlistFormat == .verilog)
        #expect(try store.loadResult().status == .success)
        #expect(resolver.records(kind: .spefRoundTrip, availability: .available).count == 3)
    }

    private final class Calls: Sendable { let count = Mutex(0) }
    private struct NewOverloadOnly: NativeRoutedPEXCalculating {
        let calls: Calls
        func calculate(input: NativeRoutedPEXInput, model: PEXOpenRCXSourceModel,
                       cornerID: PEXCornerID, limits: NativeRoutedPEXLimits,
                       isCancelled: () -> Bool) throws(NativeRoutedPEXError) -> NativeRoutedPEXResult {
            throw .unsupportedNumericalLaw(reason: "Legacy overload must never be selected")
        }
        func calculate(input: NativeRoutedPEXInput, model: PEXOpenRCXSourceModel,
                       groundCapacitanceModel: PEXRoutedGroundCapacitanceModel,
                       maximumCellSpanDatabaseUnits: Int32, cornerID: PEXCornerID,
                       limits: NativeRoutedPEXLimits, isCancelled: @Sendable () -> Bool)
            throws(NativeRoutedPEXError) -> NativeRoutedPEXResult {
            calls.count.withLock { $0 += 1 }
            guard groundCapacitanceModel.cornerID == cornerID, maximumCellSpanDatabaseUnits == 1000 else {
                throw .unsupportedNumericalLaw(reason: "Prepared ground corner/span was not forwarded")
            }
            return try UnionSheetRoutedPEXCalculator().calculate(input: input, model: model,
                groundCapacitanceModel: groundCapacitanceModel, maximumCellSpanDatabaseUnits: maximumCellSpanDatabaseUnits,
                cornerID: cornerID, limits: limits, isCancelled: isCancelled)
        }
    }
    @Test func protocolInjectionCallsOnlyNewRequirementAndBindsFreshEvidence() async throws {
        let f = try RoutedPreparationFixture()
        defer { cleanup(f) }
        let calls = Calls()
        let adapter = try NativePEXAdapter(routedCalculator: NewOverloadOnly(calls: calls))
        let context = try f.context()
        try await adapter.prepare(context)
        let result = try await adapter.execute(context)
        #expect(calls.count.withLock { $0 } == 1)
        let bytes = try Data(contentsOf: context.rawOutputDirectory.appending(path: NativeRoutedPEXExecutionEvidence.sourceFileName))
        let observed = try JSONDecoder().decode(NativeRoutedPEXExecutionEvidence.self, from: bytes)
        let prepared = try DefaultNativeRoutedPEXInputPreparer().prepare(context: context,
            requiredCornerIDs: context.requestedCornerIDs, isCancelled: { false })
        let image = try NativePEXCodeImage.measure()
        let identity = result.executionIdentity
        try observed.requireBinding(to: prepared, context: context, policy: NativePEXBackendPolicy(adapter: adapter),
            image: image, identity: identity)
        #expect(observed.model == prepared.model && observed.groundCapacitanceModel == prepared.groundCapacitanceModel)
        let original = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for mutation in ["legacy", "missing-law", "zero-span", "span", "corner", "ground", "source-reference", "fact", "identity"] {
            var changed = original
            switch mutation {
            case "legacy": changed["version"] = 1
            case "missing-law": changed.removeValue(forKey: "algorithm")
            case "zero-span": changed["maximumCellSpanDatabaseUnits"] = 0
            case "span": changed["maximumCellSpanDatabaseUnits"] = 2000
            case "corner": changed["cornerID"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PEXCornerID("foreign")))
            case "ground":
                var ground = try #require(changed["groundCapacitanceModel"] as? [String: Any])
                var layers = try #require(ground["layers"] as? [[String: Any]])
                layers[0]["areaPicofaradsPerSquareMicron"] = 123.0; ground["layers"] = layers
                changed["groundCapacitanceModel"] = ground
            case "source-reference": changed["sourceReferences"] = []
            case "fact":
                changed["inputDigest"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
                    ContentDigest(algorithm: .sha256, hexadecimalValue: String(repeating: "ab", count: 32))))
            default:
                var runtime = try #require(changed["executionIdentity"] as? [String: Any])
                var producer = try #require(runtime["producer"] as? [String: Any])
                producer["version"] = "3.1.0"; runtime["producer"] = producer; changed["executionIdentity"] = runtime
            }
            let data = try JSONSerialization.data(withJSONObject: changed)
            do {
                let decoded = try JSONDecoder().decode(NativeRoutedPEXExecutionEvidence.self, from: data)
                try decoded.requireBinding(to: prepared, context: context, policy: NativePEXBackendPolicy(adapter: adapter),
                    image: image, identity: identity)
                Issue.record("Altered routed evidence was accepted: \(mutation)")
            } catch { /* Altered transport cannot acquire checked source/runtime binding. */ }
        }
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.configURL)) as? [String: Any])
        object["version"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: f.configURL)
        #expect(throws: NativeRoutedPEXPreparationError.self) {
            _ = try DefaultNativeRoutedPEXInputPreparer().prepare(context: context,
                requiredCornerIDs: context.requestedCornerIDs, isCancelled: { false })
        }
    }

    private struct LegacyOnly: NativeRoutedPEXCalculating {
        let calls: Calls
        func calculate(input: NativeRoutedPEXInput, model: PEXOpenRCXSourceModel,
                       cornerID: PEXCornerID, limits: NativeRoutedPEXLimits,
                       isCancelled: () -> Bool) throws(NativeRoutedPEXError) -> NativeRoutedPEXResult {
            calls.count.withLock { $0 += 1 }
            throw .unsupportedNumericalLaw(reason: "Legacy overload was invoked")
        }
    }
    @Test func legacyOnlyConformerRefusesNewLawWithoutFallbackOrCanonicalSuccess() async throws {
        let f = try RoutedPreparationFixture()
        defer { cleanup(f) }
        let calls = Calls(), adapter = try NativePEXAdapter(routedCalculator: LegacyOnly(calls: calls))
        let context = try f.context()
        try await adapter.prepare(context)
        do {
            _ = try await adapter.execute(context)
            Issue.record("A legacy-only calculator acquired union-sheet success")
        } catch let failure as PEXAdapterExecutionFailure {
            guard let cause = failure.underlyingError as? NativeRoutedPEXError,
                  case .unsupportedNumericalLaw = cause else { Issue.record("Original unsupported cause was lost"); return }
            #expect(failure.generatedArtifacts.allSatisfy { $0.url.lastPathComponent != NativeRoutedPEXExecutionEvidence.resultFileName })
        }
        #expect(calls.count.withLock { $0 } == 0)
        #expect(!FileManager.default.fileExists(atPath: context.rawOutputDirectory.appending(path: NativeRoutedPEXExecutionEvidence.resultFileName).path))
    }

    private func replayContext(_ request: PEXRunRequest, corner: PEXCornerID, raw: URL) throws -> PEXExecutionContext {
        guard case .inline(let technology) = request.technology else { throw PEXError.invalidInput("Inline captured technology is required") }
        guard let selected = request.corners.first(where: { $0.id == corner }) else { throw PEXError.invalidInput("Captured request lacks the replay corner") }
        return .init(runID: .init(), corner: selected, requestedCornerIDs: request.corners.map(\.id), layoutURL: request.layoutURL, layoutFormat: request.layoutFormat,
            sourceNetlistURL: request.sourceNetlistURL, sourceNetlistFormat: request.sourceNetlistFormat, topCell: request.topCell,
            technology: technology, nativeInput: request.nativeInput, executionInputArtifacts: request.executionInputArtifacts,
            options: request.options, workingDirectory: raw, rawOutputDirectory: raw)
    }

    private func evidence<Value: Decodable>(_ type: Value.Type, file: String, corner: PEXCornerID,
        resolver: PEXArtifactResolver) throws -> Value {
        let record = try #require(resolver.records(kind: .processEvidence, cornerID: corner, availability: .available)
            .first { $0.declaration.relativePath.stringValue.hasSuffix(file) })
        return try JSONDecoder().decode(type, from: Data(contentsOf: resolver.validatedURL(for: record)))
    }
    private func cliExecutable() throws -> URL {
        var directory = Bundle.module.bundleURL.deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appending(path: "pexengine")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw PEXError.invalidInput("The built pexengine executable is required for routed CLI verification")
    }
    private func cleanup(_ f: RoutedPreparationFixture) {
        do { try f.remove() }
        catch { Issue.record("Routed runtime fixture cleanup failed: \(error)") }
    }
}
