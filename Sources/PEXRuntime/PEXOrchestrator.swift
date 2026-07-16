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
        let runID = PEXRunID()
        let startedAt = Date()
        var allWarnings: [PEXWarning] = []

        try pipeline.validateRequest(request)

        let technology = try technologyResolver.resolve(request.technology)
        let technologiesByCorner = try request.technologyByCorner.reduce(into: [:]) { result, entry in
            result[entry.key] = try technologyResolver.resolve(entry.value)
        }

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
        let workspace = PEXRunWorkspace(baseURL: baseURL, runID: runID)
        let cornerIDs = effectiveRequest.corners.map(\.id)
        try workspace.createDirectories(corners: cornerIDs)

        let store = PEXArtifactStore(workspace: workspace)
        let recorder = PEXArtifactRecorder(workspace: workspace)
        let inputArtifacts = try captureInputs(
            request: effectiveRequest,
            technology: technology,
            technologiesByCorner: technologiesByCorner,
            recorder: recorder
        )
        let capturedRequest = try recorder.capturedRequest(
            effectiveRequest,
            inputArtifacts: inputArtifacts
        )
        let extractorRequest = PEXExtractorRunRequest(
            runRequest: capturedRequest,
            processProfile: effectiveRequest.processProfile,
            capabilities: adapter.capabilities
        )

        let cornerOutcomes = await executeCorners(
            request: effectiveRequest,
            adapter: adapter,
            technology: technology,
            technologiesByCorner: technologiesByCorner,
            workspace: workspace,
            runID: runID,
            recorder: recorder,
            warnings: &allWarnings,
            cancellationCheck: cancellationCheck
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

        let requestHash = try PEXRequestHash.compute(for: effectiveRequest, inputArtifacts: inputArtifacts)

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
        let allArtifacts = inputArtifacts + cornerArtifacts + [reportArtifact]
        let extractorRun = makeExtractorRun(
            request: extractorRequest,
            readiness: extractorReadiness,
            status: status,
            cornerOutcomes: cornerOutcomes,
            artifactIDs: allArtifacts.map { $0.id.rawValue }
        )
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
                    artifactIDs: outcome.artifacts.map { $0.id.rawValue },
                    failure: outcome.failure
                )
            },
            artifacts: allArtifacts,
            warnings: allWarnings,
            extractorRun: extractorRun,
            resumedFromRunID: resumedFromRunID
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
            metrics: metrics,
            extractorRun: extractorRun,
            resumedFromRunID: resumedFromRunID
        )
    }

    private func toolReadiness(
        adapter: any PEXAdapter,
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
            processProfile: profile,
            backendSelection: request.backendSelection,
            options: request.options,
            workingDirectory: request.workingDirectory
        )
    }

    private func validateExecutionGate(
        request: PEXRunRequest,
        adapter: any PEXAdapter,
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
        technology: TechnologyIR,
        technologiesByCorner: [String: TechnologyIR],
        recorder: PEXArtifactRecorder
    ) throws -> [PEXArtifactRecord] {
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
        case .inline:
            artifacts.append(try recorder.captureInlineTechnology(
                technology,
                id: "input-technologyInput",
                destinationFilename: "technology.json"
            ))
        }
        for cornerID in request.technologyByCorner.keys.sorted() {
            let input = request.technologyByCorner[cornerID]!
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
            case .inline:
                guard let cornerTechnology = technologiesByCorner[cornerID] else {
                    throw PEXError.internalInvariantViolation(
                        "Resolved per-corner technology is missing for corner '\(cornerID)'"
                    )
                }
                artifacts.append(try recorder.captureInlineTechnology(
                    cornerTechnology,
                    id: artifactID,
                    destinationFilename: filename
                ))
            }
        }
        if let profile = request.processProfile {
            var deckEntries: [(identifier: String, path: String)] = []
            if let primaryDeckPath = profile.primaryDeckPath {
                deckEntries.append((identifier: "primary", path: primaryDeckPath))
            }
            deckEntries.append(contentsOf: profile.cornerDeckPaths.map { entry in
                (identifier: "corner-\(entry.key)", path: entry.value)
            })
            var capturedPaths: Set<String> = []
            var capturedDeckIDs: Set<String> = []
            for entry in deckEntries.sorted(by: { $0.identifier < $1.identifier }) {
                guard capturedPaths.insert(entry.path).inserted else { continue }
                var deckArtifact = try recorder.captureProcessProfileDeck(
                    path: entry.path,
                    identifier: entry.identifier
                )
                if !capturedDeckIDs.insert(deckArtifact.id.rawValue).inserted {
                    let collisionSeed = Data("\(entry.identifier)\n\(entry.path)".utf8)
                    let suffix = String(PEXRequestHash.compute(from: collisionSeed).value.prefix(10))
                    deckArtifact = try recorder.captureProcessProfileDeck(
                        path: entry.path,
                        identifier: "\(entry.identifier)-\(suffix)"
                    )
                    guard capturedDeckIDs.insert(deckArtifact.id.rawValue).inserted else {
                        throw PEXError.internalInvariantViolation(
                            "Process profile deck artifact identifiers are not unique"
                        )
                    }
                }
                artifacts.append(deckArtifact)
            }
        }
        artifacts.append(try recorder.recordRequest(request, inputArtifacts: artifacts))
        return artifacts
    }

    private func executeCorners(
        request: PEXRunRequest,
        adapter: any PEXAdapter,
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
                    layoutURL: request.layoutURL,
                    sourceNetlistURL: request.sourceNetlistURL,
                    sourceNetlistFormat: request.sourceNetlistFormat,
                    topCell: request.topCell,
                    technology: cornerTechnology,
                    processProfile: request.processProfile,
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

    private func sanitizeTechnologyCornerID(_ value: String) -> String {
        let base = value.isEmpty ? "corner" : value
        return base.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "-"
        }.map(String.init).joined()
    }

    private func executeSingleCorner(
        adapter: any PEXAdapter,
        context: PEXExecutionContext,
        store: PEXArtifactStore,
        recorder: PEXArtifactRecorder,
        options: PEXRunOptions
    ) async -> PEXCornerExecutionOutcome {
        let cornerStart = Date()
        var retainedArtifacts: [PEXArtifactRecord] = []
        do {
            let outcome = try await executeSuccessfulCorner(
                adapter: adapter,
                context: context,
                store: store,
                recorder: recorder,
                options: options,
                cornerStart: cornerStart,
                retainedArtifacts: &retainedArtifacts
            )
            await adapter.cleanup(context)
            return outcome
        } catch {
            let outcome = executeFailedCorner(
                error: error,
                retainedArtifacts: retainedArtifacts,
                context: context,
                recorder: recorder,
                cornerStart: cornerStart
            )
            await adapter.cleanup(context)
            return outcome
        }
    }

    private func executeSuccessfulCorner(
        adapter: any PEXAdapter,
        context: PEXExecutionContext,
        store: PEXArtifactStore,
        recorder: PEXArtifactRecorder,
        options: PEXRunOptions,
        cornerStart: Date,
        retainedArtifacts: inout [PEXArtifactRecord]
    ) async throws -> PEXCornerExecutionOutcome {
        let cornerID = context.corner.id
        let execution = try await pipeline.executeCorner(adapter: adapter, context: context)
        let rawOutput = execution.rawOutput
        var artifacts = try recordBackendArtifacts(
            execution: execution,
            rawOutput: rawOutput,
            recorder: recorder,
            cornerID: cornerID
        )
        retainedArtifacts = artifacts

        let parseContext = PEXParseContext(
            cornerID: cornerID,
            runID: context.runID,
            topCell: context.topCell,
            technology: context.technology,
            options: context.options
        )
        let ir = try pipeline.parseOutput(raw: rawOutput, context: parseContext)
        let (validatedIR, validationWarnings) = try pipeline.validateIR(ir, strict: options.strictValidation)

        var connectivityWarnings: [PEXWarning] = []
        if options.sourceConnectivityPolicy != .disabled {
            let connectivityReport = try PEXSourceConnectivityChecker().check(
                sourceNetlistURL: context.sourceNetlistURL,
                sourceNetlistFormat: context.sourceNetlistFormat,
                ir: validatedIR
            )
            artifacts.append(try recorder.recordSourceConnectivityReport(
                connectivityReport,
                cornerID: cornerID
            ))
            retainedArtifacts = artifacts
            if options.sourceConnectivityPolicy == .strict && !connectivityReport.isSatisfied {
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

        artifacts.append(try recordIRArtifact(
            validatedIR,
            context: context,
            store: store,
            recorder: recorder,
            options: options
        ))
        retainedArtifacts = artifacts
        let spiceOutcome = recordSPICEBackannotationArtifact(
            validatedIR,
            context: context,
            recorder: recorder
        )
        let spefOutcome = recordSPEFRoundTripArtifact(
            validatedIR,
            context: context,
            recorder: recorder
        )
        artifacts.append(contentsOf: spiceOutcome.artifacts)
        artifacts.append(contentsOf: spefOutcome.artifacts)

        let cornerEnd = Date()
        let result = PEXCornerResult(
            cornerID: cornerID,
            status: .success,
            ir: validatedIR,
            rawOutputURLs: rawOutput.fileURLs,
            logURL: rawOutput.logURL,
            warnings: validationWarnings + connectivityWarnings + spiceOutcome.warnings + spefOutcome.warnings,
            metrics: PEXCornerMetrics(
                durationSeconds: cornerEnd.timeIntervalSince(cornerStart),
                netCount: validatedIR.nets.count,
                elementCount: validatedIR.elements.count,
                peakMemoryBytes: nil
            )
        )
        return PEXCornerExecutionOutcome(result: result, artifacts: artifacts)
    }

    private func recordBackendArtifacts(
        execution: PEXAdapterExecutionResult,
        rawOutput: PEXRawOutput,
        recorder: PEXArtifactRecorder,
        cornerID: PEXCornerID
    ) throws -> [PEXArtifactRecord] {
        var artifacts: [PEXArtifactRecord] = []
        for generated in execution.generatedArtifacts {
            artifacts.append(try recorder.recordGeneratedArtifact(generated))
        }
        if artifacts.filter({ $0.matches(kind: .rawOutput) && $0.cornerID == cornerID }).isEmpty {
            for url in rawOutput.fileURLs {
                artifacts.append(try recorder.recordExistingArtifact(
                    url: url,
                    kind: .rawOutput,
                    stage: .backendExecution,
                    cornerID: cornerID
                ))
            }
        }
        if let logURL = rawOutput.logURL,
           artifacts.filter({ $0.matches(kind: .log) && $0.cornerID == cornerID }).isEmpty {
            artifacts.append(try recorder.recordExistingArtifact(
                url: logURL,
                kind: .log,
                stage: .backendExecution,
                cornerID: cornerID
            ))
        }
        return artifacts
    }

    private func recordIRArtifact(
        _ ir: ParasiticIR,
        context: PEXExecutionContext,
        store: PEXArtifactStore,
        recorder: PEXArtifactRecorder,
        options: PEXRunOptions
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
                id: "ir-\(cornerID.value)"
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

    private func recordSPEFRoundTripArtifact(
        _ ir: ParasiticIR,
        context: PEXExecutionContext,
        recorder: PEXArtifactRecorder
    ) -> PEXCornerArtifactRecordingOutcome {
        let cornerID = context.corner.id
        let spefURL = context.workingDirectory.appending(path: "spef").appending(path: "\(cornerID.value).spef")
        do {
            try SPEFWriter().write(ir, to: spefURL)
            let artifact = try recorder.recordExistingArtifact(
                url: spefURL,
                kind: .spefRoundTrip,
                stage: .persistence,
                cornerID: cornerID,
                id: "spef-roundtrip-\(cornerID.value)",
                provenance: PEXArtifactProvenance(note: "SPEF regenerated from canonical ParasiticIR")
            )
            return PEXCornerArtifactRecordingOutcome(artifacts: [artifact], warnings: [])
        } catch {
            return missingSPEFRoundTripOutcome(
                error: error,
                context: context,
                recorder: recorder,
                spefURL: spefURL
            )
        }
    }

    private func recordSPICEBackannotationArtifact(
        _ ir: ParasiticIR,
        context: PEXExecutionContext,
        recorder: PEXArtifactRecorder
    ) -> PEXCornerArtifactRecordingOutcome {
        let cornerID = context.corner.id
        let spiceURL = context.workingDirectory.appending(path: "spice").appending(path: "\(cornerID.value).cir")
        do {
            try PEXSPICEWriter(options: PEXSPICEWriterOptions(
                subcircuitName: "PEX_\(context.topCell)_\(cornerID.value)"
            )).write(ir, to: spiceURL)
            let artifact = try recorder.recordExistingArtifact(
                url: spiceURL,
                kind: .spiceBackannotation,
                stage: .persistence,
                cornerID: cornerID,
                id: "spice-backannotation-\(cornerID.value)",
                provenance: PEXArtifactProvenance(note: "Deterministic SPICE fragment generated from canonical ParasiticIR")
            )
            return PEXCornerArtifactRecordingOutcome(artifacts: [artifact], warnings: [])
        } catch {
            let warning = PEXWarning(
                stage: .persistence,
                cornerID: cornerID,
                message: "Failed to write SPICE backannotation artifact: \(error)"
            )
            do {
                let artifact = try recorder.recordMissingArtifact(
                    kind: .spiceBackannotation,
                    stage: .persistence,
                    cornerID: cornerID,
                    expectedURL: spiceURL,
                    id: "spice-backannotation-\(cornerID.value)",
                    note: "SPICE backannotation generation failed: \(error)"
                )
                return PEXCornerArtifactRecordingOutcome(artifacts: [artifact], warnings: [warning])
            } catch {
                return PEXCornerArtifactRecordingOutcome(
                    artifacts: [],
                    warnings: [warning, PEXWarning(
                        stage: .persistence,
                        cornerID: cornerID,
                        message: "Failed to record missing SPICE backannotation artifact: \(error)"
                    )]
                )
            }
        }
    }

    private func missingSPEFRoundTripOutcome(
        error: any Error,
        context: PEXExecutionContext,
        recorder: PEXArtifactRecorder,
        spefURL: URL
    ) -> PEXCornerArtifactRecordingOutcome {
        let cornerID = context.corner.id
        var warnings = [
            PEXWarning(
                stage: .persistence,
                cornerID: cornerID,
                message: "Failed to write SPEF round-trip artifact: \(error)"
            ),
        ]
        do {
            let artifact = try recorder.recordMissingArtifact(
                kind: .spefRoundTrip,
                stage: .persistence,
                cornerID: cornerID,
                expectedURL: spefURL,
                id: "spef-roundtrip-\(cornerID.value)",
                note: "SPEF round-trip generation failed: \(error)"
            )
            return PEXCornerArtifactRecordingOutcome(artifacts: [artifact], warnings: warnings)
        } catch {
            warnings.append(PEXWarning(
                stage: .persistence,
                cornerID: cornerID,
                message: "Failed to record missing SPEF round-trip artifact: \(error)"
            ))
            return PEXCornerArtifactRecordingOutcome(artifacts: [], warnings: warnings)
        }
    }

    private func executeFailedCorner(
        error: any Error,
        retainedArtifacts: [PEXArtifactRecord],
        context: PEXExecutionContext,
        recorder: PEXArtifactRecorder,
        cornerStart: Date
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
                failureKind: (error as? PEXError)?.kind,
                message: message,
                suggestedActions: suggestedActions(for: stage)
            )
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
            .map { context.workingDirectory.appending(path: $0.locator.location.value) }
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

private struct PEXCornerArtifactRecordingOutcome: Sendable {
    let artifacts: [PEXArtifactRecord]
    let warnings: [PEXWarning]
}
