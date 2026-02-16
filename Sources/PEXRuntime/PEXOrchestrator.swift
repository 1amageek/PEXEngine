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

        // 1. Validate request
        try pipeline.validateRequest(request)

        // 2. Resolve technology
        let technology = try technologyResolver.resolve(request.technology)

        // 3. Resolve adapter
        let adapter = try pipeline.resolveAdapter(for: request.backendSelection.backendID)

        // 4. Create workspace
        let baseURL = request.workingDirectory ?? URL(filePath: FileManager.default.temporaryDirectory.path(percentEncoded: false))
        let workspace = PEXRunWorkspace(baseURL: baseURL, runID: runID)
        let cornerIDs = request.corners.map(\.id)
        try workspace.createDirectories(corners: cornerIDs)

        // 5. Save request
        let store = PEXArtifactStore(workspace: workspace)
        try store.saveRequest(request)

        // 6. Execute corners with bounded parallelism
        let cornerResults = await executeCorners(
            request: request,
            adapter: adapter,
            technology: technology,
            workspace: workspace,
            runID: runID,
            warnings: &allWarnings
        )

        let finishedAt = Date()

        // 7. Compute overall status
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

        // 8. Compute request hash
        let requestHash: PEXRequestHash
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(request)
            requestHash = PEXRequestHash.compute(from: data)
        } catch {
            requestHash = PEXRequestHash("unknown")
        }

        // 9. Build metrics
        let metrics = PEXRunMetrics(
            totalDurationSeconds: finishedAt.timeIntervalSince(startedAt),
            cornerCount: cornerResults.count,
            successCount: successCount,
            failureCount: failureCount
        )

        // 10. Build artifacts index
        let artifacts = store.buildArtifactIndex(corners: cornerIDs)

        // 11. Build result
        let result = PEXRunResult(
            runID: runID,
            requestHash: requestHash,
            status: status,
            startedAt: startedAt,
            finishedAt: finishedAt,
            cornerResults: cornerResults,
            warnings: allWarnings,
            artifacts: artifacts,
            metrics: metrics
        )

        // 12. Save manifest
        let manifest = PEXManifest(
            runID: runID,
            requestHash: requestHash,
            backendID: request.backendSelection.backendID,
            status: status,
            startedAt: startedAt,
            finishedAt: finishedAt,
            corners: cornerResults.map { cr in
                PEXManifest.CornerEntry(
                    cornerID: cr.cornerID,
                    status: cr.status,
                    rawFiles: cr.rawOutputURLs.map(\.lastPathComponent),
                    irFile: cr.ir != nil ? "\(cr.cornerID.value).json" : nil,
                    logFile: cr.logURL?.lastPathComponent
                )
            },
            warnings: allWarnings.map(\.message)
        )
        do {
            try store.saveManifest(manifest)
        } catch {
            allWarnings.append(PEXWarning(stage: .persistence, message: "Failed to save manifest: \(error)"))
        }

        // 13. Generate and save report
        let reportGenerator = PEXReportGenerator()
        let report = reportGenerator.generateSummary(result: result)
        do {
            try store.saveReport(report)
        } catch {
            allWarnings.append(PEXWarning(stage: .reporting, message: "Failed to save report: \(error)"))
        }

        return result
    }

    private func executeCorners(
        request: PEXRunRequest,
        adapter: any PEXAdapter,
        technology: TechnologyIR,
        workspace: PEXRunWorkspace,
        runID: PEXRunID,
        warnings: inout [PEXWarning]
    ) async -> [PEXCornerResult] {
        let store = PEXArtifactStore(workspace: workspace)
        let maxJobs = max(1, request.options.maxParallelJobs)

        // Execute corners with bounded parallelism
        var results: [PEXCornerResult] = []

        await withTaskGroup(of: PEXCornerResult.self) { group in
            var running = 0

            for corner in request.corners {
                if running >= maxJobs {
                    if let result = await group.next() {
                        results.append(result)
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
                        store: store,
                        options: request.options
                    )
                }
                running += 1
            }

            for await result in group {
                results.append(result)
            }
        }

        // Collect warnings from corner results after TaskGroup completes (thread-safe)
        for result in results {
            warnings.append(contentsOf: result.warnings)
        }
        return results
    }

    private func executeSingleCorner(
        adapter: any PEXAdapter,
        context: PEXExecutionContext,
        store: PEXArtifactStore,
        options: PEXRunOptions
    ) async -> PEXCornerResult {
        let cornerStart = Date()
        let cornerID = context.corner.id

        do {
            // Execute adapter
            let rawOutput = try await pipeline.executeCorner(adapter: adapter, context: context)

            // Parse output
            let parseContext = PEXParseContext(
                cornerID: cornerID,
                runID: context.runID,
                technology: context.technology,
                options: context.options
            )
            let ir = try pipeline.parseOutput(raw: rawOutput, context: parseContext)

            // Validate IR
            let (validatedIR, validationWarnings) = try pipeline.validateIR(ir, strict: options.strictValidation)

            // Persist IR
            var cornerWarnings = validationWarnings
            if options.emitIRJSON {
                do {
                    try store.saveIR(validatedIR, for: cornerID)
                } catch {
                    cornerWarnings.append(PEXWarning(stage: .persistence, cornerID: cornerID, message: "Failed to save IR: \(error)"))
                }
            }

            // Cleanup
            await adapter.cleanup(context)

            let cornerEnd = Date()
            return PEXCornerResult(
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
        } catch {
            await adapter.cleanup(context)
            let cornerEnd = Date()
            return PEXCornerResult(
                cornerID: cornerID,
                status: .failed,
                ir: nil,
                rawOutputURLs: [],
                logURL: nil,
                warnings: [],
                metrics: PEXCornerMetrics(
                    durationSeconds: cornerEnd.timeIntervalSince(cornerStart),
                    netCount: 0,
                    elementCount: 0,
                    peakMemoryBytes: nil
                )
            )
        }
    }
}
