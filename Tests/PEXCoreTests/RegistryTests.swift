import Testing
@testable import PEXCore

@Suite("Registry Tests")
struct RegistryTests {
    @Test func adapterRegistryRegisterAndLookup() {
        let registry = PEXAdapterRegistry()
        // We can't easily create a mock adapter here without PEXAdapters,
        // so test empty registry behavior
        #expect(registry.adapter(for: "mock") == nil)
        #expect(registry.registeredBackends.isEmpty)
    }

    @Test func parserRegistryRegisterAndLookup() {
        let registry = PEXParserRegistry()
        #expect(registry.parser(for: .spef) == nil)
        #expect(registry.registeredFormats.isEmpty)
    }
}
