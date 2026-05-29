import PEXCore
import PEXAdapters
import PEXParsers

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
        // list/doctor commands via PEXDefaultBackends so they never drift.
        let adapters = PEXAdapterRegistry(adapters: PEXDefaultBackends.makeAll())
        let parsers = PEXParserRegistry()
        parsers.register(SPEFPEXParser())
        parsers.register(MagicSPICEParasiticParser())
        return DefaultPEXEngine(
            adapterRegistry: adapters,
            parserRegistry: parsers
        )
    }

    public func run(_ request: PEXRunRequest) async throws -> PEXRunResult {
        try await orchestrator.run(request)
    }
}
