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
        // The mock backend stays registered (mandatory for tests/preview); the
        // real Magic backend is selectable by backendID "magic" and fails loudly
        // at execute time if the toolchain is not installed.
        let adapters = PEXAdapterRegistry(adapters: [MockPEXAdapter(), MagicPEXAdapter()])
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
