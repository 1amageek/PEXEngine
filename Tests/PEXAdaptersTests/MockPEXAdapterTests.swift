import Testing
@testable import PEXCore
@testable import PEXAdapters
@testable import PEXTestSupport

@Suite("Mock PEX adapter")
struct MockPEXAdapterTests {
    @Test func adapterCapabilities() {
        let adapter = MockPEXAdapter()
        #expect(adapter.backendID == "mock")
        #expect(adapter.capabilities.supportsCouplingCaps)
        #expect(adapter.capabilities.supportsCornerSweep)
        #expect(adapter.capabilities.nativeOutputFormats.contains(.spef))
    }

    @Test func generatorProducesSPEF() {
        let generator = MockParasiticGenerator(
            topCell: "TEST",
            corner: PEXCorner(id: "tt_25c_1v0"),
            includeCouplingCaps: true
        )
        let spef = generator.generateSPEF()
        #expect(spef.contains("*SPEF"))
        #expect(spef.contains("*DESIGN \"TEST\""))
        #expect(spef.contains("*D_NET"))
        #expect(spef.contains("*CAP"))
        #expect(spef.contains("*RES"))
    }

    @Test func generatorProducesValidIR() {
        let generator = MockParasiticGenerator(
            topCell: "TEST",
            corner: PEXCorner(id: "tt"),
            includeCouplingCaps: true
        )
        let ir = generator.generateParasiticIR()
        #expect(!ir.nets.isEmpty)
        #expect(!ir.elements.isEmpty)
        #expect(ir.cornerID.value == "tt")
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test func temperatureScalesValues() {
        let coldCorner = PEXCorner(id: PEXCornerID("cold"), name: "cold", temperature: -40)
        let hotCorner = PEXCorner(id: PEXCornerID("hot"), name: "hot", temperature: 125)
        let coldIR = MockParasiticGenerator(topCell: "T", corner: coldCorner).generateParasiticIR()
        let hotIR = MockParasiticGenerator(topCell: "T", corner: hotCorner).generateParasiticIR()
        let coldTotal = coldIR.elements.reduce(0.0) { $0 + $1.value }
        let hotTotal = hotIR.elements.reduce(0.0) { $0 + $1.value }
        #expect(hotTotal > coldTotal)
    }
}
