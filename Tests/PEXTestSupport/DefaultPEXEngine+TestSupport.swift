import PEXAdapters
import PEXCore
import PEXParsers
import PEXRuntime

public extension DefaultPEXEngine {
    static func withTestDefaults() -> DefaultPEXEngine {
        DefaultPEXEngine(
            adapterRegistry: PEXAdapterRegistry(
                adapters: [MockPEXAdapter(), MagicPEXAdapter()]
            ),
            parserRegistry: PEXDefaultParsers.makeRegistry()
        )
    }
}
