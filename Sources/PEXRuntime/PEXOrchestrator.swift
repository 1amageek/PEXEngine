import Foundation
import PEXCore
import PEXAdapters
import PEXParsers
import PEXPersistence

public actor PEXOrchestrator {
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
        let runID = PEXRunID()
        let startedAt = Date()
        var allWarnings: [PEXWarning] = []

        try pipeline.validateRequest(request)

        let technology = try technologyResolver.resolve(request.technology)

        let adapter = try pipeline.resolveAdapter(for: request.backendSelection.backendID)

        let baseURL = request.workingDirectory ?? URL(filePath: FileManager.default.temporaryDirectory.path(percentEncoded: false))
        let workspace = PEXRunWorkspace(baseURL: baseURL, runID: runID)
        let cornerIDs = request.corners.map(\.id)
        try workspace.createDirectories(corners: cornerIDs)

        let store = PEXArtifactStore(workspace: workspace)
        let recorder = PEXArtifactRecorder(workspace: workspace)
        let inputArtifacts = try captureInputs(request: request, technology: technology, recorder: recorder)

        let cornerOutcomes = await executeCorners(
            request: request,
            adapter: adapter,
            technology: technology,
            workspace: workspace,
            runID: runID,
            recorder: recorder,
            warnings: &allWarnings
        )
        let cornerResults = cornerOutcomes.map(\.result)

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

        let requestHash = try PEXRequestHash.compute(for: request, inputArtifacts: inputArtifacts)

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
                id: "report-summary"
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
        let manifest = PEXArtifactManifest(
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
                    artifactIDs: outcome.artifacts.map(\.id),
                    failure: outcome.failure
                )
            },
            artifacts: inputArtifacts + cornerArtifacts + [reportArtifact],
            warnings: allWarnings
        )
        try store.saveManifest(manifest)

        return PEXRunResult(
            runID: runID,
            requestHash: requestHash,
            status: status,
            startedAt: startedAt,
            finishedAt: finishedAt,
            cornerResults: cornerResults,
            warnings: allWarnings,
            artifacts: manifest,
            manifestURL: workspace.manifestURL,
            metrics: metrics
        )
    }

    private func captureInputs(
        request: PEXRunRequest,
        technology: TechnologyIR,
        recorder: PEXArtifactRecorder
    ) throws -> [PEXArtifactRecord] {
        var artifacts: [PEXArtifactRecord] = []
        artifacts.append(try recorder.captureInput(url: request.layoutURL, kind: .layoutInput))
        artifacts.append(try recorder.captureInput(url: request.sourceNetlistURL, kind: .netlistInput))
        switch request.technology {
        case .jsonFile(let url):
            artifacts.append(try recorder.captureInput(url: url, kind: .technologyInput))
        case .inline:
            artifacts.append(try recorder.captureInlineTechnology(technology))
        }
        artifacts.append(try recorder.recordRequest(request, inputArtifacts: artifacts))
        return artifacts
    }

    private func executeCorners(
        request: PEXRunRequest,
        adapter: any PEXAdapter,
        technology: TechnologyIR,
        workspace: PEXRunWorkspace,
        runID: PEXRunID,
        recorder: PEXArtifactRecorder,
        warnings: inout [PEXWarning]
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

                let context = PEXExecutionContext(
                    runID: runID,
                    corner: corner,
                    layoutURL: request.layoutURL,
                    sourceNetlistURL: request.sourceNetlistURL,
                    topCell: request.topCell,
                    technology: technology,
                    options: request.options,
                    workingDirectory: workspace.runDirectory,
                    rawOutputDirectory: workspace.cornerRawDirectory(corner.id)
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

        for outcome in outcomes {
            warnings.append(contentsOf: outcome.result.warnings)
        }
        return outcomes
    }

    private func executeSingleCorner(
        adapter: any PEXAdapter,
        context: PEXExecutionContext,
        store: PEXArtifactStore,
        recorder: PEXArtifactRecorder,
        options: PEXRunOptions
    ) async -> PEXCornerExecutionOutcome {
        let cornerStart = Date()
        let cornerID = context.corner.id
        var artifacts: [PEXArtifactRecord] = []
        var artifactWarnings: [PEXWarning] = []

        do {
            let execution = try await pipeline.executeCorner(adapter: adapter, context: context)
            let rawOutput = execution.rawOutput
            for generated in execution.generatedArtifacts {
                artifacts.append(try recorder.recordGeneratedArtifact(generated))
            }
            if artifacts.filter({ $0.kind == .rawOutput && $0.cornerID == cornerID }).isEmpty {
                for url in rawOutput.fileURLs {
                    artifacts.append(try recorder.recordExistingArtifact(
                        url: url,
                        kind: .rawOutput,
                        stage: .backendExecution,
                        cornerID: cornerID
                    ))
                }
            }
            if let logURL = rawOutput.logURL, artifacts.filter({ $0.kind == .log && $0.cornerID == cornerID }).isEmpty {
                artifacts.append(try recorder.recordExistingArtifact(
                    url: logURL,
                    kind: .log,
                    stage: .backendExecution,
                    cornerID: cornerID
                ))
            }

            let parseContext = PEXParseContext(
                cornerID: cornerID,
                runID: context.runID,
                technology: context.technology,
                options: context.options
            )
            let ir = try pipeline.parseOutput(raw: rawOutput, context: parseContext)

            let (validatedIR, validationWarnings) = try pipeline.validateIR(ir, strict: options.strictValidation)

            let cornerWarnings = validationWarnings
            if options.emitIRJSON {
                try store.saveIR(validatedIR, for: cornerID)
                artifacts.append(try recorder.recordExistingArtifact(
                    url: context.workingDirectory.appending(path: "ir").appending(path: "\(cornerID.value).json"),
                    kind: .parasiticIR,
                    stage: .persistence,
                    cornerID: cornerID,
                    id: "ir-\(cornerID.value)"
                ))
            } else {
                artifacts.append(try recorder.recordOmittedArtifact(
                    kind: .parasiticIR,
                    stage: .persistence,
                    cornerID: cornerID,
                    expectedURL: context.workingDirectory.appending(path: "ir").appending(path: "\(cornerID.value).json"),
                    id: "ir-\(cornerID.value)",
                    note: "IR JSON emission disabled"
                ))
            }

            await adapter.cleanup(context)

            let cornerEnd = Date()
            let result = PEXCornerResult(
                cornerID: cornerID,
                status: .success,
                ir: validatedIR,
                rawOutputURLs: rawOutput.fileURLs,
                logURL: rawOutput.logURL,
                warnings: cornerWarnings,
                metrics: PEXCornerMetrics(
                    durationSeconds: cornerEnd.timeIntervalSince(cornerStart),
                    netCount: validatedIR.nets.count,
                    elementCount: validatedIR.elements.count,
                    peakMemoryBytes: nil
                )
            )
            return PEXCornerExecutionOutcome(result: result, artifacts: artifacts)
        } catch {
            if let failure = error as? PEXAdapterExecutionFailure {
                for generated in failure.generatedArtifacts {
                    do {
                        artifacts.append(try recorder.recordGeneratedArtifact(generated))
                    } catch {
                        artifactWarnings.append(PEXWarning(
                            stage: .persistence,
                            cornerID: cornerID,
                            message: "Failed to record partial artifact \(generated.url.path(percentEncoded: false)): \(error)"
                        ))
                    }
                }
            }
            await adapter.cleanup(context)
            let cornerEnd = Date()
            let pexError = error as? PEXError
            let stage = pexError?.stage ?? (error as? PEXAdapterExecutionFailure)?.stage ?? .backendExecution
            let message = pexError?.message ?? (error as? PEXAdapterExecutionFailure)?.message ?? String(describing: error)
            if stage == .parsing || stage == .irValidation {
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
                    artifactWarnings.append(PEXWarning(
                        stage: .persistence,
                        cornerID: cornerID,
                        message: "Failed to record missing IR artifact: \(error)"
                    ))
                }
            }
            let rawOutputURLs = artifacts.filter { $0.kind == .rawOutput && $0.status == .available }.map { context.workingDirectory.appending(path: $0.relativePath.value) }
            let logURL = artifacts.first { $0.kind == .log && $0.status == .available }.map { context.workingDirectory.appending(path: $0.relativePath.value) }
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
                    message: message,
                    suggestedActions: suggestedActions(for: stage)
                )
            )
        }
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

    init(
        result: PEXCornerResult,
        artifacts: [PEXArtifactRecord],
        failure: PEXArtifactFailure? = nil
    ) {
        self.result = result
        self.artifacts = artifacts
        self.failure = failure
    }
}
