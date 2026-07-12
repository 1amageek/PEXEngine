import Testing
@testable import PEXCore

@Suite("Technology IR Validator Tests")
struct TechnologyIRValidatorTests {
    @Test func validatorReportsSemanticTechnologyIssues() {
        let technology = TechnologyIR(
            processName: "sky130A",
            stack: [
                TechnologyLayer(name: "met1", order: 1, thickness: 0, material: "metal", resistivity: -1),
                TechnologyLayer(name: "met1", order: 1, thickness: 0.3, material: "metal", resistivity: 2.8e-8),
            ],
            logicalToPhysicalLayerMap: ["M1": "missing"],
            vias: [TechnologyVia(name: "via1", topLayer: "missing", bottomLayer: "met1", resistance: -1)],
            defaultExtractionRules: ExtractionRules(minCapacitanceF: -1, minResistanceOhm: .infinity, reductionPolicy: .none),
            backendHints: [:]
        )

        let issues = TechnologyIRValidator().validate(technology)
        let codes = Set(issues.map(\.code))
        #expect(codes.contains("layer_name_duplicate"))
        #expect(codes.contains("layer_thickness_invalid"))
        #expect(codes.contains("layer_map_target_unknown"))
        #expect(codes.contains("via_top_layer_unknown"))
        #expect(codes.contains("min_capacitance_invalid"))
        #expect(codes.contains("min_resistance_invalid"))
    }

    @Test func validatorAcceptsMinimalPhysicalTechnology() {
        let technology = TechnologyIR(
            processName: "sky130A",
            stack: [TechnologyLayer(name: "met1", order: 1, thickness: 0.35, material: "metal", resistivity: 2.8e-8)],
            logicalToPhysicalLayerMap: ["M1": "met1"],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )

        #expect(TechnologyIRValidator().validate(technology).isEmpty)
    }
}
