import Foundation
import CircuiteFoundation
import CircuiteFoundationFoundation
import CircuiteFoundationCrypto
import PEXCore
import PEXAdapters
import PEXParsers
import PEXPersistence

public actor PEXOrchestrator {
    public struct PendingCleanupFailure: Error, Sendable {
        public let failures: [PEXProcessCleanupFailure]
    }
    private let pipeline: PEXPipeline
    private let technologyResolver: TechnologyResolver

    public init(
        adapterRegistry: PEXAdapterRegistry,
        parserRegistry: PEXParserRegistry
    ) {
        self.pipeline = PEXPipeline(
            adapterRegistry: adapterRegistry,
            parserRegistry: parserRegistry
        )
        self.technologyResolver = TechnologyResolver()
    }

    public func run(_ request: PEXRunRequest) async throws -> PEXRunResult {
        try await run(request, cancellationCheck: nil, resumedFromRunID: nil)
    }

    public func run(
        _ request: PEXRunRequest,
        cancellationCheck: PEXExecutionContext.CancellationCheck?
    ) async throws -> PEXRunResult {
        try await run(
            request,
            cancellationCheck: cancellationCheck,
            resumedFromRunID: nil
        )
    }

    public func run(
        _ request: PEXRunRequest,
        cancellationCheck: PEXExecutionContext.CancellationCheck?,
        resumedFromRunID: PEXRunID?
    ) async throws -> PEXRunResult {
        let parent: PEXRunResult?
        if let resumedFromRunID {
            guard let baseURL = request.workingDirectory else {
                throw PEXError.invalidInput("A parent-linked run requires its retained parent working directory")
            }
            parent = try PEXArtifactStore(workspace: .init(baseURL: baseURL, runID: resumedFromRunID)).loadResult()
        } else {
            parent = nil
        }
        return try await executeRun(request, cancellationCheck: cancellationCheck, retrying: parent)
    }

    func run(
        _ request: PEXRunRequest,
        cancellationCheck: PEXExecutionContext.CancellationCheck?,
        retrying previousResult: PEXRunResult
    ) async throws -> PEXRunResult {
        try await executeRun(request, cancellationCheck: cancellationCheck, retrying: previousResult)
    }

    private func executeRun(
        _ suppliedRequest: PEXRunRequest,
        cancellationCheck: PEXExecutionContext.CancellationCheck?,
        retrying previousResult: PEXRunResult?
    ) async throws -> PEXRunResult {
        let parent = try previousResult.map(loadRetryParent)
        let request: PEXRunRequest
        if let parent {
            let failedIDs = Set(parent.manifest.corners.filter { $0.status == .failed }.map(\.cornerID))
            let selectedIDs = Set(suppliedRequest.corners.map(\.id))
            guard parent.manifest.status == .failed || parent.manifest.status == .partialSuccess,
                  !selectedIDs.isEmpty, selectedIDs.isSubset(of: failedIDs),
                  let observed = parent.manifest.backendExecutions.first,
                  parent.manifest.backendExecutions.allSatisfy({ $0.hasSameImplementation(as: observed) }),
                  parent.request.backendSelection.expectedProducer.map({ $0 == observed.producer }) ?? true else {
                throw PEXError.invalidInput("Retry requires failed parent corners and a consistent retained implementation identity")
            }
            if let expected = suppliedRequest.backendSelection.expectedProducer, expected != observed.producer {
                throw PEXError.invalidInput("Retry producer differs from the retained parent implementation")
            }
            request = bindingRetryProducer(suppliedRequest, to: observed.producer)
        } else {
            request = suppliedRequest
        }
        let resumedFromRunID = parent?.manifest.runID
        let runID = PEXRunID()
        let startedAt = Date()
        var allWarnings: [PEXWarning] = []

        try pipeline.validateRequest(request)

        let adapter = try pipeline.resolveAdapter(for: request.backendSelection.backendID)
        try pipeline.validateInputFiles(request)
        let extractorReadiness = toolReadiness(
            adapter: adapter,
            processProfile: request.processProfile
        )
        let effectiveRequest = requestWithProcessProfile(
            request,
            profile: request.processProfile ?? extractorReadiness.processProfile
        )
        try validateExecutionGate(
            request: effectiveRequest,
            adapter: adapter,
            readiness: extractorReadiness
        )
        let baseURL = effectiveRequest.workingDirectory ?? URL(filePath: FileManager.default.temporaryDirectory.path(percentEncoded: false))
        if let previousResult,
           baseURL.standardizedFileURL != previousResult.manifestURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL {
            throw PEXError.invalidInput("A parent-linked retry must retain its parent's lineage base; relocate the complete history before retrying")
        }
        let workspace = PEXRunWorkspace(baseURL: baseURL, runID: runID)
        let cornerIDs = effectiveRequest.corners.map(\.id)
        try workspace.createDirectories(corners: cornerIDs)

        let store = PEXArtifactStore(workspace: workspace)
        let recorder = PEXArtifactRecorder(workspace: workspace)
        let capturedInputs = try captureInputs(request: effectiveRequest, recorder: recorder)
        let inputArtifacts = capturedInputs.artifacts
        let capturedRequest = capturedInputs.request
        if let parent {
            let selectedIDs = Set(capturedRequest.corners.map(\.id))
            let previousIdentity = try PEXRequestHash.computeRetryIdentity(for: parent.request,
                inputArtifacts: retryInputArtifacts(parent.manifest), selecting: selectedIDs)
            let currentIdentity = try PEXRequestHash.computeRetryIdentity(for: capturedRequest,
                inputArtifacts: inputArtifacts, selecting: selectedIDs)
            guard previousIdentity == currentIdentity else {
                throw PEXError.invalidInput("Retry inputs, model, configuration or selected corner conditions differ from the retained parent")
            }
        }
        try validateDeclaredExecutionInputs(capturedRequest.executionInputArtifacts, request: capturedRequest)
        let technology = try technologyResolver.resolve(capturedRequest.technology)
        let technologiesByCorner = try capturedRequest.technologyByCorner.reduce(into: [:]) { result, entry in
            result[entry.key] = try technologyResolver.resolve(entry.value)
        }
        try pipeline.validateNativeCalibrationInputs(capturedRequest, technology: technology,
            technologiesByCorner: technologiesByCorner, inputArtifacts: inputArtifacts)
        let requestHash = try PEXRequestHash.compute(for: capturedRequest, inputArtifacts: inputArtifacts)
        let extractorRequest = PEXExtractorRunRequest(
            runRequest: capturedRequest,
            processProfile: capturedRequest.processProfile,
            capabilities: adapter.capabilities
        )

        let cornerOutcomes = await executeCorners(
            request: capturedRequest,
            adapter: adapter,
            technology: technology,
            technologiesByCorner: technologiesByCorner,
            workspace: workspace,
            runID: runID,
            recorder: recorder,
            warnings: &allWarnings,
            cancellationCheck: cancellationCheck
        )
        // All corner tasks are joined before transferring unresolved cleanup authority.
        let pending = cornerOutcomes.compactMap(\.pendingCleanup)
        if !pending.isEmpty { throw PendingCleanupFailure(failures: pending) }
        let cornerResults = cornerOutcomes.map(\.result)

        let backendExecutions = try validatedBackendExecutions(from: cornerOutcomes)
        if let parent, let observed = parent.manifest.backendExecutions.first {
            guard backendExecutions.allSatisfy({ $0.hasSameImplementation(as: observed) }) else {
                throw PEXError(kind: .backendExecutionFailed, stage: .backendExecution,
                    runID: runID, backendID: request.backendSelection.backendID,
                    message: "Retry observed a different backend implementation; no parent-linked result was published")
            }
        }
        guard let primaryExecution = backendExecutions.first else {
            throw PEXError(
                kind: .backendExecutionFailed,
                stage: .backendExecution,
                backendID: effectiveRequest.backendSelection.backendID,
                message: "PEX produced no measured backend execution identity."
            )
        }

        let finishedAt = Date()

        let successCount = cornerResults.filter { $0.status == .success }.count
        let failureCount = cornerResults.filter { $0.status == .failed }.count
        let status: PEXRunStatus
        if failureCount == 0 {
            status = .success
        } else if successCount > 0 {
            status = .partialSuccess
        } else {
            status = .failed
        }

        let metrics = PEXRunMetrics(
            totalDurationSeconds: finishedAt.timeIntervalSince(startedAt),
            cornerCount: cornerResults.count,
            successCount: successCount,
            failureCount: failureCount
        )

        let reportGenerator = PEXReportGenerator()
        let report = reportGenerator.generateSummary(
            cornerResults: cornerResults,
            status: status,
            runID: runID,
            requestHash: requestHash,
            metrics: metrics,
            warnings: allWarnings
        )

        let reportArtifact: PEXArtifactRecord
        do {
            try store.saveReport(report)
            reportArtifact = try recorder.recordExistingArtifact(
                url: workspace.reportURL,
                kind: .report,
                stage: .reporting,
                id: "report-summary",
                producer: primaryExecution.producer
            )
        } catch {
            allWarnings.append(PEXWarning(stage: .reporting, message: "Failed to save report: \(error)"))
            reportArtifact = try recorder.recordMissingArtifact(
                kind: .report,
                stage: .reporting,
                expectedURL: workspace.reportURL,
                id: "report-summary",
                note: "report persistence failed"
            )
        }

        let cornerArtifacts = cornerOutcomes.flatMap(\.artifacts)
        let allArtifacts = inputArtifacts + cornerArtifacts + [reportArtifact]
        let provenance = try ExecutionProvenance(
            producer: primaryExecution.producer,
            inputs: effectiveRequest.executionInputArtifacts.isEmpty
                ? inputArtifacts.compactMap(\.reference)
                : effectiveRequest.executionInputArtifacts,
            invocation: primaryExecution.invocation,
            environment: primaryExecution.environment,
            configurationDigest: try ContentDigest(
                algorithm: .sha256,
                hexadecimalValue: requestHash.value
            ),
            startedAt: startedAt,
            completedAt: finishedAt
        )
        let extractorRun = makeExtractorRun(
            request: extractorRequest,
            readiness: extractorReadiness,
            status: status,
            cornerOutcomes: cornerOutcomes,
            artifactIDs: allArtifacts.map { $0.id.rawValue }
        )
        let evidence = try EvidenceManifest.contentAddressed(
            provenance: provenance,
            artifacts: allArtifacts.compactMap(\.reference),
            digester: SHA256ContentDigester()
        )
        let manifest = try PEXArtifactManifest(
            runID: runID,
            requestHash: requestHash,
            backendID: request.backendSelection.backendID,
            status: status,
            startedAt: startedAt,
            finishedAt: finishedAt,
            corners: cornerOutcomes.map { outcome in
                PEXArtifactCorner(
                    cornerID: outcome.result.cornerID,
                    status: outcome.result.status,
                    artifactIDs: outcome.artifacts.map { $0.id.rawValue },
                    failure: outcome.failure
                )
            },
            artifacts: allArtifacts,
            warnings: allWarnings,
            extractorRun: extractorRun,
            resumedFromRunID: resumedFromRunID,
            backendExecutions: backendExecutions,
            provenance: provenance,
            evidence: evidence
        )
        try store.saveManifest(manifest)

        return try PEXRunResult(
            runID: runID,
            requestHash: requestHash,
            status: status,
            startedAt: startedAt,
            finishedAt: finishedAt,
            cornerResults: cornerResults,
            warnings: allWarnings,
            artifactManifest: manifest,
            manifestURL: workspace.manifestURL,
            metrics: metrics,
            extractorRun: extractorRun,
            resumedFromRunID: resumedFromRunID
        )
    }

    private func retryInputArtifacts(_ manifest: PEXArtifactManifest) -> [PEXArtifactRecord] {
        manifest.artifacts.filter { $0.stage == .inputValidation || $0.stage == .technologyResolution }
    }

    private func loadRetryParent(_ result: PEXRunResult) throws -> (request: PEXRunRequest, manifest: PEXArtifactManifest) {
        let workspace = PEXRunWorkspace(baseURL: result.manifestURL.deletingLastPathComponent().deletingLastPathComponent(), runID: result.runID)
        guard workspace.manifestURL.standardizedFileURL == result.manifestURL.standardizedFileURL else {
            throw PEXError.invalidInput("Retry manifest location does not identify the retained parent run")
        }
        let store = PEXArtifactStore(workspace: workspace)
        let manifest = try store.loadManifest()
        guard manifest.runID == result.runID, manifest.requestHash == result.requestHash,
              manifest.status == result.status,
              try PEXArtifactStore.encodeManifest(manifest) == PEXArtifactStore.encodeManifest(result.artifactManifest),
              manifest.corners.count == result.cornerResults.count,
              Set(result.cornerResults.map(\.cornerID)).count == result.cornerResults.count,
              result.cornerResults.allSatisfy({ corner in
                  manifest.corners.contains { $0.cornerID == corner.cornerID && $0.status == corner.status }
              }) else {
            throw PEXError.invalidInput("Retry result does not match its immutable retained parent manifest")
        }
        let request = try store.loadRequest()
        guard try PEXRequestHash.compute(for: request, inputArtifacts: retryInputArtifacts(manifest)) == manifest.requestHash else {
            throw PEXError.persistenceFailed("Retained parent request hash does not match its captured inputs")
        }
        return (request, manifest)
    }

    private func bindingRetryProducer(_ request: PEXRunRequest, to producer: ProducerIdentity) -> PEXRunRequest {
        PEXRunRequest(layoutURL: request.layoutURL, layoutFormat: request.layoutFormat,
            sourceNetlistURL: request.sourceNetlistURL, sourceNetlistFormat: request.sourceNetlistFormat,
            topCell: request.topCell, corners: request.corners, technology: request.technology,
            technologyByCorner: request.technologyByCorner, nativeInput: request.nativeInput,
            processProfile: request.processProfile,
            backendSelection: .init(backendID: request.backendSelection.backendID,
                executablePath: request.backendSelection.executablePath,
                environmentOverrides: request.backendSelection.environmentOverrides, expectedProducer: producer),
            options: request.options, workingDirectory: request.workingDirectory,
            executionInputArtifacts: request.executionInputArtifacts)
    }

    private func toolReadiness(
        adapter: any PEXExtracting,
        processProfile: PEXProcessProfileReference?
    ) -> PEXExtractorToolReadiness {
        if let provider = adapter as? PEXAdapterReadinessProviding {
            return provider.toolReadiness(processProfile: processProfile)
        }
        return PEXExtractorToolReadiness(
            backendID: adapter.backendID,
            status: .unknown,
            reason: "Backend does not expose a typed extractor readiness provider.",
            processProfile: processProfile,
            capabilities: adapter.capabilities,
            diagnostics: [
                PEXExtractorDiagnostic(
                    diagnosticID: "\(adapter.backendID):readiness-provider-missing",
                    code: "readiness_provider_missing",
                    severity: .warning,
                    message: "Backend can be executed, but tool readiness cannot be inspected before execution.",
                    suggestedActions: ["run_backend_with_artifact_capture"]
                )
            ],
            suggestedActions: ["run_backend_with_artifact_capture"]
        )
    }

    private func requestWithProcessProfile(
        _ request: PEXRunRequest,
        profile: PEXProcessProfileReference?
    ) -> PEXRunRequest {
        PEXRunRequest(
            layoutURL: request.layoutURL,
            layoutFormat: request.layoutFormat,
            sourceNetlistURL: request.sourceNetlistURL,
            sourceNetlistFormat: request.sourceNetlistFormat,
            topCell: request.topCell,
            corners: request.corners,
            technology: request.technology,
            technologyByCorner: request.technologyByCorner,
            nativeInput: request.nativeInput,
            processProfile: profile,
            backendSelection: request.backendSelection,
            options: request.options,
            workingDirectory: request.workingDirectory,
            executionInputArtifacts: request.executionInputArtifacts
        )
    }

    private func validateExecutionGate(
        request: PEXRunRequest,
        adapter: any PEXExtracting,
        readiness: PEXExtractorToolReadiness
    ) throws {
        if let executablePath = request.backendSelection.executablePath,
           !FileManager.default.isExecutableFile(atPath: executablePath) {
            throw PEXError(
                kind: .adapterUnavailable,
                stage: .adapterPreparation,
                backendID: adapter.backendID,
                message: "Selected backend executable is not executable: \(executablePath)"
            )
        }
        if readiness.status == .blocked {
            throw PEXError(
                kind: .adapterUnavailable,
                stage: .adapterPreparation,
                backendID: adapter.backendID,
                message: "PEX backend '\(adapter.backendID)' readiness is blocked: \(readiness.reason)"
            )
        }

        let capabilities = readiness.capabilities ?? adapter.capabilities
        let supportsCornerSweep = capabilities.supportsCornerSweep ||
            ((adapter as? any PEXAdapterReadinessProviding)?.supportsCornerSweep(
                corners: request.corners,
                processProfile: request.processProfile
            ) ?? false)
        if request.corners.count > 1 && !supportsCornerSweep {
            throw PEXError.invalidInput(
                "PEX backend '\(adapter.backendID)' does not support corner sweep, but \(request.corners.count) corners were requested"
            )
        }
    }

    private func makeExtractorRun(
        request: PEXExtractorRunRequest,
        readiness: PEXExtractorToolReadiness,
        status: PEXRunStatus,
        cornerOutcomes: [PEXCornerExecutionOutcome],
        artifactIDs: [String]
    ) -> PEXExtractorRunResult {
        let cornerSummaries = cornerOutcomes.map { outcome in
            let rawArtifactIDs = outcome.artifacts
                .filter { $0.matches(kind: .rawOutput) && $0.availability == .available }
                .map { $0.id.rawValue }
            let irArtifactID = outcome.artifacts.first {
                $0.matches(kind: .parasiticIR) && $0.availability == .available
            }?.id.rawValue
            let spefRoundTripArtifactID = outcome.artifacts.first {
                $0.matches(kind: .spefRoundTrip) && $0.availability == .available
            }?.id.rawValue
            let spiceBackannotationArtifactID = outcome.artifacts.first {
                $0.matches(kind: .spiceBackannotation) && $0.availability == .available
            }?.id.rawValue
            let connectivityArtifactID = outcome.artifacts.first {
                $0.matches(kind: .sourceConnectivityReport) && $0.availability == .available
            }?.id.rawValue
            let totals = parasiticTotals(outcome.result.ir)
            return PEXExtractorRunResult.CornerSummary(
                cornerID: outcome.result.cornerID,
                status: outcome.result.status,
                netCount: outcome.result.metrics.netCount,
                elementCount: outcome.result.metrics.elementCount,
                rawOutputCount: outcome.result.rawOutputURLs.count,
                warningCount: outcome.result.warnings.count,
                unitSystem: totals.unitSystem,
                totalGroundCapF: totals.totalGroundCapF,
                totalCouplingCapF: totals.totalCouplingCapF,
                totalCapacitanceF: totals.totalCapacitanceF,
                totalResistanceOhm: totals.totalResistanceOhm,
                rawOutputArtifactIDs: rawArtifactIDs,
                parasiticIRArtifactID: irArtifactID,
                spefRoundTripArtifactID: spefRoundTripArtifactID,
                spiceBackannotationArtifactID: spiceBackannotationArtifactID,
                sourceConnectivityArtifactID: connectivityArtifactID,
                failureStage: outcome.failure?.stage,
                failureMessage: outcome.failure?.message
            )
        }
        let failureDiagnostics = cornerOutcomes.compactMap { outcome -> PEXExtractorDiagnostic? in
            guard let failure = outcome.failure else { return nil }
            return PEXExtractorDiagnostic(
                diagnosticID: "\(request.backendID):corner:\(outcome.result.cornerID.value):\(failure.stage.rawValue)",
                code: "corner_failed",
                severity: failure.stage == .backendExecution ? .error : .warning,
                message: failure.message,
                suggestedActions: failure.suggestedActions
            )
        }
        let comparisonNotes = request.technologyByCorner.isEmpty
            ? []
            : [
                "Per-corner technology overrides are active; multi-corner spreads are process-specific unless the supplied corner metadata establishes PVT equivalence.",
            ]
        let comparisonBasis: PEXExtractorMultiCornerComparisonBasis = request.technologyByCorner.isEmpty
            ? .sharedTechnology
            : .perCornerTechnology
        return PEXExtractorRunResult(
            request: request,
            readiness: readiness,
            status: status,
            cornerResults: cornerSummaries,
            artifactIDs: artifactIDs,
            multiCorner: PEXExtractorMultiCornerSummary(
                cornerResults: cornerSummaries,
                comparisonBasis: comparisonBasis,
                additionalNotes: comparisonNotes
            ),
            diagnostics: readiness.diagnostics + failureDiagnostics
        )
    }

    private func parasiticTotals(_ ir: ParasiticIR?) -> (
        unitSystem: String?,
        totalGroundCapF: Double?,
        totalCouplingCapF: Double?,
        totalCapacitanceF: Double?,
        totalResistanceOhm: Double?
    ) {
        guard let ir else {
            return (nil, nil, nil, nil, nil)
        }
        let ground = ir.nets.reduce(0) { $0 + $1.totalGroundCapF }
        let coupling = ir.nets.reduce(0) { $0 + $1.totalCouplingCapF }
        let resistance = ir.nets.reduce(0) { $0 + $1.totalResistanceOhm }
        return ("canonical", ground, coupling, ground + coupling, resistance)
    }

    private func captureInputs(
        request: PEXRunRequest,
        recorder: PEXArtifactRecorder
    ) throws -> (request: PEXRunRequest, artifacts: [PEXArtifactRecord]) {
        var artifacts: [PEXArtifactRecord] = []
        artifacts.append(try recorder.captureInput(url: request.layoutURL, kind: .layoutInput))
        artifacts.append(try recorder.captureInput(url: request.sourceNetlistURL, kind: .netlistInput))
        switch request.technology {
        case .jsonFile(let url):
            artifacts.append(try recorder.captureInput(
                url: url,
                kind: .technologyInput,
                id: "input-technologyInput",
                destinationFilename: "technology.json"
            ))
        case .inline(let technology):
            artifacts.append(try recorder.captureInlineTechnology(
                technology,
                id: "input-technologyInput",
                destinationFilename: "technology.json"
            ))
        }
        for cornerID in request.technologyByCorner.keys.sorted() {
            guard let input = request.technologyByCorner[cornerID] else {
                throw PEXError.internalInvariantViolation(
                    "Per-corner technology input is missing for corner '\(cornerID)'"
                )
            }
            let artifactID = "input-technologyInput-\(sanitizeTechnologyCornerID(cornerID))"
            let filename = "technology-\(sanitizeTechnologyCornerID(cornerID)).json"
            switch input {
            case .jsonFile(let url):
                artifacts.append(try recorder.captureInput(
                    url: url,
                    kind: .technologyInput,
                    id: artifactID,
                    destinationFilename: filename
                ))
            case .inline(let cornerTechnology):
                artifacts.append(try recorder.captureInlineTechnology(
                    cornerTechnology,
                    id: artifactID,
                    destinationFilename: filename
                ))
            }
        }
        if let profile = request.processProfile {
            artifacts.append(contentsOf: try recorder.captureProcessProfileInputs(profile))
        }
        if let nativeInput = request.nativeInput {
            artifacts.append(contentsOf: try recorder.captureNativeInputs(nativeInput))
        }
        let captured = try recorder.captureRunRequest(request, inputArtifacts: artifacts)
        artifacts.append(captured.artifact)
        return (captured.request, artifacts)
    }

    private func validateDeclaredExecutionInputs(
        _ references: [ArtifactReference],
        request: PEXRunRequest
    ) throws {
        guard !references.isEmpty else {
            return
        }
        guard Set(references).count == references.count else {
            throw PEXError.invalidInput("PEX execution input artifacts must be unique.")
        }
        try requireDeclaredInput(
            request.layoutURL,
            kind: .layout,
            in: references
        )
        try requireDeclaredInput(
            request.sourceNetlistURL,
            kind: .netlist,
            in: references
        )
    }

    private func requireDeclaredInput(
        _ url: URL,
        kind: ArtifactKind,
        in references: [ArtifactReference]
    ) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let digest = try SHA256ContentDigester().digest(data: data)
        let matches = references.filter {
            $0.kind == kind
                && $0.digest == digest
                && $0.byteCount == UInt64(data.count)
        }
        guard matches.count == 1 else {
            throw PEXError.invalidInput(
                "PEX \(kind.rawValue) input is not bound to one exact execution artifact."
            )
        }
    }

    private func executeCorners(
        request: PEXRunRequest,
        adapter: any PEXExtracting,
        technology: TechnologyIR,
        technologiesByCorner: [String: TechnologyIR],
        workspace: PEXRunWorkspace,
        runID: PEXRunID,
        recorder: PEXArtifactRecorder,
        warnings: inout [PEXWarning],
        cancellationCheck: PEXExecutionContext.CancellationCheck?
    ) async -> [PEXCornerExecutionOutcome] {
        let maxJobs = max(1, request.options.maxParallelJobs)

        var outcomes: [PEXCornerExecutionOutcome] = []

        await withTaskGroup(of: PEXCornerExecutionOutcome.self) { group in
            var running = 0

            for corner in request.corners {
                if running >= maxJobs {
                    if let outcome = await group.next() {
                        outcomes.append(outcome)
                        running -= 1
                    }
                }

                let cornerTechnology = technologiesByCorner[corner.id.value] ?? technology
                let context = PEXExecutionContext(
                    runID: runID,
                    corner: corner,
                    requestedCornerIDs: request.corners.map(\.id),
                    layoutURL: request.layoutURL,
                    layoutFormat: request.layoutFormat,
                    sourceNetlistURL: request.sourceNetlistURL,
                    sourceNetlistFormat: request.sourceNetlistFormat,
                    topCell: request.topCell,
                    technology: cornerTechnology,
                    nativeInput: request.nativeInput,
                    processProfile: request.processProfile,
                    executionInputArtifacts: request.executionInputArtifacts,
                    backendSelection: request.backendSelection,
                    options: request.options,
                    workingDirectory: workspace.runDirectory,
                    rawOutputDirectory: workspace.cornerRawDirectory(corner.id),
                    cancellationCheck: cancellationCheck
                )

                group.addTask {
                    await self.executeSingleCorner(
                        adapter: adapter,
                        context: context,
                        store: PEXArtifactStore(workspace: workspace),
                        recorder: recorder,
                        options: request.options
                    )
                }
                running += 1
            }

            for await outcome in group {
                outcomes.append(outcome)
            }
        }

        let cornerOrder = Dictionary(uniqueKeysWithValues: request.corners.enumerated().map { ($0.element.id, $0.offset) })
        outcomes.sort {
            (cornerOrder[$0.result.cornerID] ?? Int.max) < (cornerOrder[$1.result.cornerID] ?? Int.max)
        }
        for outcome in outcomes {
            warnings.append(contentsOf: outcome.result.warnings)
        }
        return outcomes
    }

    private func validatedBackendExecutions(
        from outcomes: [PEXCornerExecutionOutcome]
    ) throws -> [PEXBackendExecutionIdentity] {
        let successful = outcomes.filter { $0.result.status == .success }
        let successfulIdentities = successful.compactMap(\.executionIdentity)
        guard successfulIdentities.count == successful.count else {
            throw PEXError.internalInvariantViolation(
                "A successful PEX corner omitted its measured backend execution identity"
            )
        }
        let identities = outcomes.compactMap(\.executionIdentity)
        guard let primary = identities.first else {
            return []
        }
        guard identities.allSatisfy({ $0.hasSameImplementation(as: primary) }) else {
            throw PEXError(
                kind: .backendExecutionFailed,
                stage: .backendExecution,
                backendID: primary.producer.identifier,
                message: "PEX backend identity changed between corner executions."
            )
        }
        return identities
    }

    private func sanitizeTechnologyCornerID(_ value: String) -> String {
        let base = value.isEmpty ? "corner" : value
        return base.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "-"
        }.map(String.init).joined()
    }

    private func executeSingleCorner(
        adapter: any PEXExtracting,
        context: PEXExecutionContext,
        store: PEXArtifactStore,
        recorder: PEXArtifactRecorder,
        options: PEXRunOptions
    ) async -> PEXCornerExecutionOutcome {
        let cornerStart = Date()
        var retainedArtifacts: [PEXArtifactRecord] = []
        var retainedExecutionIdentity: PEXBackendExecutionIdentity?
        do {
            let outcome = try await executeSuccessfulCorner(
                adapter: adapter,
                context: context,
                store: store,
                recorder: recorder,
                options: options,
                cornerStart: cornerStart,
                retainedArtifacts: &retainedArtifacts,
                retainedExecutionIdentity: &retainedExecutionIdentity
            )
            await adapter.cleanup(context)
            return outcome
        } catch {
            let outcome = executeFailedCorner(
                error: error,
                retainedArtifacts: retainedArtifacts,
                context: context,
                recorder: recorder,
                cornerStart: cornerStart,
                executionIdentity: retainedExecutionIdentity
                    ?? (error as? PEXAdapterExecutionFailure)?.executionIdentity
            )
            await adapter.cleanup(context)
            return outcome
        }
    }

    private func executeSuccessfulCorner(
        adapter: any PEXExtracting,
        context: PEXExecutionContext,
        store: PEXArtifactStore,
        recorder: PEXArtifactRecorder,
        options: PEXRunOptions,
        cornerStart: Date,
        retainedArtifacts: inout [PEXArtifactRecord],
        retainedExecutionIdentity: inout PEXBackendExecutionIdentity?
    ) async throws -> PEXCornerExecutionOutcome {
        let cornerID = context.corner.id
        let execution = try await pipeline.executeCorner(adapter: adapter, context: context)
        retainedExecutionIdentity = execution.executionIdentity
        try recordBackendArtifacts(
            execution: execution,
            recorder: recorder,
            cornerID: cornerID,
            retainedArtifacts: &retainedArtifacts
        )
        var artifacts = retainedArtifacts
        try pipeline.validateExecutionIdentity(execution.executionIdentity, context: context, backendID: adapter.backendID)

        let parseContext = PEXParseContext(
            cornerID: cornerID,
            runID: context.runID,
            topCell: context.topCell,
            technology: context.technology,
            options: context.options
        )
        let (validatedIR, validationWarnings) = try pipeline.canonicalIR(from: execution, context: parseContext)

        artifacts.append(try recordIRArtifact(validatedIR, context: context, store: store, recorder: recorder,
            options: options, producer: execution.executionIdentity.producer))
        retainedArtifacts = artifacts
        var connectivityWarnings: [PEXWarning] = []
        if options.sourceConnectivityPolicy != .disabled || adapter.backendID == "native" {
            let connectivityReport = try PEXSourceConnectivityChecker().check(
                sourceNetlistURL: context.sourceNetlistURL,
                sourceNetlistFormat: context.sourceNetlistFormat,
                ir: validatedIR, topCell: context.topCell
            )
            artifacts.append(try recorder.recordSourceConnectivityReport(
                connectivityReport,
                cornerID: cornerID,
                producer: execution.executionIdentity.producer
            ))
            retainedArtifacts = artifacts
            if (options.sourceConnectivityPolicy == .strict || adapter.backendID == "native") && !connectivityReport.isSatisfied {
                throw PEXError(
                    kind: .irValidationFailed,
                    stage: .irValidation,
                    cornerID: cornerID,
                    backendID: adapter.backendID,
                    message: "Source-netlist connectivity validation failed: \(connectivityReport.diagnostics.joined(separator: "; "))"
                )
            }
            connectivityWarnings = connectivityReport.diagnostics.map { diagnostic in
                PEXWarning(
                    stage: .irValidation,
                    cornerID: cornerID,
                    message: "Source-netlist connectivity: \(diagnostic)"
                )
            }
        }

        try recordRequiredStandardArtifact(
            kind: .spiceBackannotation, relativePath: "spice/\(cornerID.value).cir",
            id: "spice-backannotation-\(cornerID.value)", context: context, recorder: recorder,
            producer: execution.executionIdentity.producer, retainedArtifacts: &retainedArtifacts
        ) { url in
            try PEXSPICEWriter(options: .init(subcircuitName: "PEX_\(context.topCell)_\(cornerID.value)")).write(validatedIR, to: url)
        }
        try recordRequiredStandardArtifact(
            kind: .spefRoundTrip, relativePath: "spef/\(cornerID.value).spef",
            id: "spef-roundtrip-\(cornerID.value)", context: context, recorder: recorder,
            producer: execution.executionIdentity.producer, retainedArtifacts: &retainedArtifacts
        ) { url in
            try SPEFWriter().write(validatedIR, to: url)
        }
        artifacts = retainedArtifacts
        if adapter.backendID == "native" {
            guard let topology = execution.physicalTopology, topology.isSatisfied else {
                throw PEXError(kind: .irValidationFailed, stage: .irValidation, cornerID: cornerID,
                    backendID: adapter.backendID,
                    message: "Native same-design topology admission failed: \(String(describing: execution.physicalTopology))")
            }
        }

        let rawURLs: [URL]
        let logURL: URL?
        switch execution.output {
        case .raw(let raw): rawURLs = raw.fileURLs; logURL = raw.logURL
        case .canonical:
            rawURLs = []
            logURL = availableArtifactURLs(kind: .log, artifacts: artifacts, context: context).first
        }
        let cornerEnd = Date()
        let result = PEXCornerResult(
            cornerID: cornerID,
            status: .success,
            ir: validatedIR,
            rawOutputURLs: rawURLs,
            logURL: logURL,
            warnings: validationWarnings + connectivityWarnings,
            metrics: PEXCornerMetrics(
                durationSeconds: cornerEnd.timeIntervalSince(cornerStart),
                netCount: validatedIR.nets.count,
                elementCount: validatedIR.elements.count,
                peakMemoryBytes: nil
            )
        )
        return PEXCornerExecutionOutcome(
            result: result,
            artifacts: artifacts,
            executionIdentity: execution.executionIdentity
        )
    }

    private func recordBackendArtifacts(
        execution: PEXAdapterExecutionResult,
        recorder: PEXArtifactRecorder,
        cornerID: PEXCornerID,
        retainedArtifacts: inout [PEXArtifactRecord]
    ) throws {
        for generated in execution.generatedArtifacts {
            retainedArtifacts.append(try recorder.recordGeneratedArtifact(generated))
        }
        guard case .raw(let rawOutput) = execution.output else { return }
        if retainedArtifacts.contains(where: { $0.matches(kind: .rawOutput) && $0.cornerID == cornerID }) == false {
            for url in rawOutput.fileURLs {
                retainedArtifacts.append(try recorder.recordExistingArtifact(
                    url: url,
                    kind: .rawOutput,
                    stage: .backendExecution,
                    cornerID: cornerID,
                    producer: execution.executionIdentity.producer
                ))
            }
        }
        if let logURL = rawOutput.logURL,
           retainedArtifacts.contains(where: { $0.matches(kind: .log) && $0.cornerID == cornerID }) == false {
            retainedArtifacts.append(try recorder.recordExistingArtifact(
                url: logURL,
                kind: .log,
                stage: .backendExecution,
                cornerID: cornerID,
                producer: execution.executionIdentity.producer
            ))
        }
    }

    private func recordIRArtifact(
        _ ir: ParasiticIR,
        context: PEXExecutionContext,
        store: PEXArtifactStore,
        recorder: PEXArtifactRecorder,
        options: PEXRunOptions,
        producer: ProducerIdentity
    ) throws -> PEXArtifactRecord {
        let cornerID = context.corner.id
        let irURL = context.workingDirectory.appending(path: "ir").appending(path: "\(cornerID.value).json")
        if options.emitIRJSON {
            try store.saveIR(ir, for: cornerID)
            return try recorder.recordExistingArtifact(
                url: irURL,
                kind: .parasiticIR,
                stage: .persistence,
                cornerID: cornerID,
                id: "ir-\(cornerID.value)",
                producer: producer
            )
        }
        return try recorder.recordOmittedArtifact(
            kind: .parasiticIR,
            stage: .persistence,
            cornerID: cornerID,
            expectedURL: irURL,
            id: "ir-\(cornerID.value)",
            note: "IR JSON emission disabled"
        )
    }

    private func recordRequiredStandardArtifact(
        kind: PEXArtifactKind,
        relativePath: String,
        id: String,
        context: PEXExecutionContext,
        recorder: PEXArtifactRecorder,
        producer: ProducerIdentity,
        retainedArtifacts: inout [PEXArtifactRecord],
        write: (URL) throws -> Void
    ) throws {
        let url = context.workingDirectory.appending(path: relativePath)
        do {
            try write(url)
            retainedArtifacts.append(try recorder.recordExistingArtifact(
                url: url, kind: kind, stage: .persistence, cornerID: context.corner.id, id: id,
                provenance: .init(note: "Required standard output generated from canonical ParasiticIR"), producer: producer
            ))
        } catch {
            let message = "Required \(kind.rawValue) output failed: \(error)"
            do {
                retainedArtifacts.append(try recorder.recordMissingArtifact(
                    kind: kind, stage: .persistence, cornerID: context.corner.id,
                    expectedURL: url, id: id, note: message
                ))
            } catch {
                throw PEXError.persistenceFailed("\(message); missing-artifact recording also failed: \(error)")
            }
            throw PEXError.persistenceFailed(message, underlying: error)
        }
    }

    private func executeFailedCorner(
        error: any Error,
        retainedArtifacts: [PEXArtifactRecord],
        context: PEXExecutionContext,
        recorder: PEXArtifactRecorder,
        cornerStart: Date,
        executionIdentity: PEXBackendExecutionIdentity?
    ) -> PEXCornerExecutionOutcome {
        let cornerID = context.corner.id
        var artifactWarnings: [PEXWarning] = []
        var artifacts = retainedArtifacts + recordPartialFailureArtifacts(
            error: error,
            recorder: recorder,
            cornerID: cornerID,
            warnings: &artifactWarnings
        )
        let stage = failureStage(for: error)
        let message = failureMessage(for: error)
        appendMissingIRArtifactIfNeeded(
            stage: stage,
            message: message,
            context: context,
            recorder: recorder,
            artifacts: &artifacts,
            warnings: &artifactWarnings
        )

        let cornerEnd = Date()
        let rawOutputURLs = availableArtifactURLs(kind: .rawOutput, artifacts: artifacts, context: context)
        let logURL = availableArtifactURLs(kind: .log, artifacts: artifacts, context: context).first
        let result = PEXCornerResult(
            cornerID: cornerID,
            status: .failed,
            ir: nil,
            rawOutputURLs: rawOutputURLs,
            logURL: logURL,
            warnings: [PEXWarning(stage: stage, cornerID: cornerID, message: message)] + artifactWarnings,
            metrics: PEXCornerMetrics(
                durationSeconds: cornerEnd.timeIntervalSince(cornerStart),
                netCount: 0,
                elementCount: 0,
                peakMemoryBytes: nil
            )
        )
        return PEXCornerExecutionOutcome(
            result: result,
            artifacts: artifacts,
            failure: PEXArtifactFailure(
                stage: stage,
                failureKind: (error as? PEXError)?.kind
                    ?? (error as? PEXAdapterExecutionFailure)?.failureKind,
                message: message,
                suggestedActions: suggestedActions(for: stage)
            ),
            executionIdentity: executionIdentity,
            pendingCleanup: (error as? PEXAdapterExecutionFailure)?.underlyingError as? PEXProcessCleanupFailure
        )
    }

    private func recordPartialFailureArtifacts(
        error: any Error,
        recorder: PEXArtifactRecorder,
        cornerID: PEXCornerID,
        warnings: inout [PEXWarning]
    ) -> [PEXArtifactRecord] {
        guard let failure = error as? PEXAdapterExecutionFailure else {
            return []
        }
        var artifacts: [PEXArtifactRecord] = []
        for generated in failure.generatedArtifacts {
            do {
                artifacts.append(try recorder.recordGeneratedArtifact(generated))
            } catch {
                warnings.append(PEXWarning(
                    stage: .persistence,
                    cornerID: cornerID,
                    message: "Failed to record partial artifact \(generated.url.path(percentEncoded: false)): \(error)"
                ))
            }
        }
        return artifacts
    }

    private func appendMissingIRArtifactIfNeeded(
        stage: PEXStage,
        message: String,
        context: PEXExecutionContext,
        recorder: PEXArtifactRecorder,
        artifacts: inout [PEXArtifactRecord],
        warnings: inout [PEXWarning]
    ) {
        guard shouldRecordMissingIR(for: stage) else {
            return
        }
        let cornerID = context.corner.id
        guard !artifacts.contains(where: { $0.matches(kind: .parasiticIR) && $0.cornerID == cornerID }) else { return }
        do {
            artifacts.append(try recorder.recordMissingArtifact(
                kind: .parasiticIR,
                stage: stage,
                cornerID: cornerID,
                expectedURL: context.workingDirectory.appending(path: "ir").appending(path: "\(cornerID.value).json"),
                id: "ir-\(cornerID.value)",
                note: message
            ))
        } catch {
            warnings.append(PEXWarning(
                stage: .persistence,
                cornerID: cornerID,
                message: "Failed to record missing IR artifact: \(error)"
            ))
        }
    }

    private func shouldRecordMissingIR(for stage: PEXStage) -> Bool {
        stage == .parsing || stage == .irValidation || stage == .persistence
    }

    private func availableArtifactURLs(
        kind: PEXArtifactKind,
        artifacts: [PEXArtifactRecord],
        context: PEXExecutionContext
    ) -> [URL] {
        artifacts
            .filter { $0.matches(kind: kind) && $0.availability == .available }
            .map { context.workingDirectory.appending(path: $0.relativePath.stringValue) }
    }

    private func failureStage(for error: any Error) -> PEXStage {
        if let pexError = error as? PEXError {
            return pexError.stage
        }
        if let failure = error as? PEXAdapterExecutionFailure {
            return failure.stage
        }
        return .backendExecution
    }

    private func failureMessage(for error: any Error) -> String {
        if let pexError = error as? PEXError {
            return pexError.message
        }
        if let failure = error as? PEXAdapterExecutionFailure {
            return failure.message
        }
        return String(describing: error)
    }

    private func suggestedActions(for stage: PEXStage) -> [String] {
        switch stage {
        case .parsing:
            return ["inspect_raw_output", "verify_output_format", "rerun_adapter_with_diagnostics"]
        case .irValidation:
            return ["inspect_ir_validation_report", "check_extraction_rules", "rerun_without_strict_validation"]
        case .backendExecution:
            return ["inspect_backend_log", "verify_backend_inputs", "rerun_backend"]
        case .persistence:
            return ["inspect_run_directory_permissions", "verify_available_disk_space"]
        default:
            return ["inspect_run_log"]
        }
    }
}

private struct PEXCornerExecutionOutcome: Sendable {
    let result: PEXCornerResult
    let artifacts: [PEXArtifactRecord]
    let failure: PEXArtifactFailure?
    let executionIdentity: PEXBackendExecutionIdentity?
    let pendingCleanup: PEXProcessCleanupFailure?

    init(
        result: PEXCornerResult,
        artifacts: [PEXArtifactRecord],
        failure: PEXArtifactFailure? = nil,
        executionIdentity: PEXBackendExecutionIdentity? = nil,
        pendingCleanup: PEXProcessCleanupFailure? = nil
    ) {
        self.result = result
        self.artifacts = artifacts
        self.failure = failure
        self.executionIdentity = executionIdentity
        self.pendingCleanup = pendingCleanup
    }
}
