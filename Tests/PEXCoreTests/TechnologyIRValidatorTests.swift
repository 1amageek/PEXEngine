import Testing
@testable import PEXCore

@Suite("Technology IR Validator Tests")
struct TechnologyIRValidatorTests {
    @Test func validatorReportsSemanticTechnologyIssues() {
        let technology = TechnologyIR(
            processName: "sky130A",
            stack: [
                TechnologyLayer(name: "met1", order: 1, material: "metal"),
                TechnologyLayer(name: "met1", order: 1, material: "metal"),
            ],
            logicalToPhysicalLayerMap: ["M1": "missing"],
            vias: [TechnologyVia(name: "via1", topLayer: "missing", bottomLayer: "met1")],
            defaultExtractionRules: ExtractionRules(minCapacitanceF: -1, minResistanceOhm: .infinity, reductionPolicy: .none),
            backendHints: [:]
        )

        let issues = TechnologyIRValidator().validate(technology)
        let codes = Set(issues.map(\.code))
        #expect(codes.contains("layer_name_duplicate"))
        #expect(codes.contains("layer_map_target_unknown"))
        #expect(codes.contains("via_top_layer_unknown"))
        #expect(codes.contains("min_capacitance_invalid"))
        #expect(codes.contains("min_resistance_invalid"))
    }

    @Test func validatorAcceptsMinimalPhysicalTechnology() {
        let technology = TechnologyIR(
            processName: "sky130A",
            stack: [TechnologyLayer(name: "met1", order: 1, material: "metal")],
            logicalToPhysicalLayerMap: ["M1": "met1"],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )

        #expect(TechnologyIRValidator().validate(technology).isEmpty)
    }
}
