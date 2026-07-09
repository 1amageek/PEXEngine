import PEXCore
import PEXAdapters

public final class DefaultPEXEngine: PEXEngineProtocol, Sendable {
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
        // Canonical backend set (mock + real Magic), shared with the CLI's
        // list/doctor commands via default factories so they never drift.
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
}
