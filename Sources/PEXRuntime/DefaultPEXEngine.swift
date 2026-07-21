import PEXCore
import PEXAdapters

public final class DefaultPEXEngine: PEXExecuting, Sendable {
    private let orchestrator: PEXOrchestrator

    public init(
        adapterRegistry: PEXAdapterRegistry,
        parserRegistry: PEXParserRegistry
    ) {
        self.orchestrator = PEXOrchestrator(
            adapterRegistry: adapterRegistry,
            parserRegistry: parserRegistry
        )
    }

    public static func withDefaults() -> DefaultPEXEngine {
        // Canonical production backends are shared with CLI discovery.
        let adapters = PEXAdapterRegistry(adapters: PEXDefaultBackends.makeAll())
        let parsers = PEXDefaultParsers.makeRegistry()
        return DefaultPEXEngine(
            adapterRegistry: adapters,
            parserRegistry: parsers
        )
    }

    public func run(_ request: PEXRunRequest) async throws -> PEXRunResult {
        try await orchestrator.run(request)
    }

    public func run(
        _ request: PEXRunRequest,
        cancellationCheck: PEXExecutionContext.CancellationCheck?
    ) async throws -> PEXRunResult {
        try await orchestrator.run(request, cancellationCheck: cancellationCheck)
    }

    public func retryFailedCorners(
        _ request: PEXRunRequest,
        from previousResult: PEXRunResult
    ) async throws -> PEXRunResult {
        guard previousResult.status == .failed || previousResult.status == .partialSuccess else {
            throw PEXError.invalidInput(
                "Only failed or partial-success PEX runs can be retried"
            )
        }
        guard previousResult.artifactManifest.backendID == request.backendSelection.backendID else {
            throw PEXError.invalidInput(
                "Retry backend '\(request.backendSelection.backendID)' does not match prior backend '\(previousResult.artifactManifest.backendID)'"
            )
        }

        let failedCornerIDs = Set(
            previousResult.cornerResults
                .filter { $0.status == .failed }
                .map(\.cornerID)
        )
        guard !failedCornerIDs.isEmpty else {
            throw PEXError.invalidInput("Prior PEX result has no failed corners to retry")
        }
        let retryCorners = request.corners.filter { failedCornerIDs.contains($0.id) }
        guard retryCorners.count == failedCornerIDs.count else {
            throw PEXError.invalidInput(
                "Retry request does not contain every failed corner from prior run"
            )
        }

        let retryRequest = PEXRunRequest(
            layoutURL: request.layoutURL,
            layoutFormat: request.layoutFormat,
            sourceNetlistURL: request.sourceNetlistURL,
            sourceNetlistFormat: request.sourceNetlistFormat,
            topCell: request.topCell,
            corners: retryCorners,
            technology: request.technology,
            technologyByCorner: request.technologyByCorner,
            processProfile: request.processProfile,
            backendSelection: request.backendSelection,
            options: request.options,
            workingDirectory: request.workingDirectory,
            executionInputArtifacts: request.executionInputArtifacts
        )
        return try await orchestrator.run(
            retryRequest,
            cancellationCheck: nil,
            resumedFromRunID: previousResult.runID
        )
    }
}
