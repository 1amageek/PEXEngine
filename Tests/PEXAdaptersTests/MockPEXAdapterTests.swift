import Testing
import Foundation
@testable import PEXCore
@testable import PEXAdapters

@Suite("MockPEXAdapter Tests")
struct MockPEXAdapterTests {
    @Test func adapterCapabilities() {
        let adapter = MockPEXAdapter()
        #expect(adapter.backendID == "mock")
        #expect(adapter.capabilities.supportsCouplingCaps == true)
        #expect(adapter.capabilities.supportsCornerSweep == true)
        #expect(adapter.capabilities.nativeOutputFormats.contains(.spef))
    }

    @Test func mockGeneratorProducesSPEF() {
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

    @Test func mockGeneratorProducesValidIR() {
        let generator = MockParasiticGenerator(
            topCell: "TEST",
            corner: PEXCorner(id: "tt"),
            includeCouplingCaps: true
        )
        let ir = generator.generateParasiticIR()
        #expect(!ir.nets.isEmpty)
        #expect(!ir.elements.isEmpty)
        #expect(ir.cornerID.value == "tt")

        let validator = ParasiticIRValidator()
        let result = validator.validate(ir)
        #expect(result.isValid, "Mock-generated IR should be valid")
    }

    @Test func temperatureScalesValues() {
        let coldCorner = PEXCorner(id: PEXCornerID("cold"), name: "cold", temperature: -40)
        let hotCorner = PEXCorner(id: PEXCornerID("hot"), name: "hot", temperature: 125)

        let coldGen = MockParasiticGenerator(topCell: "T", corner: coldCorner)
        let hotGen = MockParasiticGenerator(topCell: "T", corner: hotCorner)

        let coldIR = coldGen.generateParasiticIR()
        let hotIR = hotGen.generateParasiticIR()

        // Hot corner should have larger parasitic values due to temperature scaling
        let coldTotal = coldIR.elements.reduce(0.0) { $0 + $1.value }
        let hotTotal = hotIR.elements.reduce(0.0) { $0 + $1.value }
        #expect(hotTotal > coldTotal)
    }
}
