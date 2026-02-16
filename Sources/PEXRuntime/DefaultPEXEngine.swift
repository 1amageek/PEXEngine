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
        let adapters = PEXAdapterRegistry(adapters: [MockPEXAdapter()])
        let parsers = PEXParserRegistry()
        parsers.register(SPEFPEXParser())
        return DefaultPEXEngine(
            adapterRegistry: adapters,
            parserRegistry: parsers
        )
    }

    public func run(_ request: PEXRunRequest) async throws -> PEXRunResult {
        try await orchestrator.run(request)
    }
}
