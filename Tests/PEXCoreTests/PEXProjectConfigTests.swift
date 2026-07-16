import Testing
import Foundation
@testable import PEXCore

@Suite("PEXProjectConfig Tests")
struct PEXProjectConfigTests {
    @Test func decodeFromJSON() throws {
        let json = """
        {
            "version": 1,
            "enabled": true,
            "topCell": "INVERTER",
            "backendID": "mock",
            "corners": ["tt_25c_1v0", "ss_125c_0v81"],
            "inputs": {
                "layout": "top.oas",
                "netlist": "top.cir",
                "technology": "tech.json",
                "technologyByCorner": {}
            },
            "output": { "workspace": ".xcircuite/pex/runs" },
            "options": {
                "includeCouplingCaps": true,
                "maxParallelJobs": 2,
                "strictValidation": false,
                "sourceConnectivityPolicy": "warn"
            }
        }
        """
        let data = Data(json.utf8)
        let config = try JSONDecoder().decode(PEXProjectConfig.self, from: data)
        #expect(config.topCell == "INVERTER")
        #expect(config.backendID == "mock")
        #expect(config.corners.count == 2)
        #expect(config.version == 1)
        #expect(config.enabled == true)
    }

    @Test(arguments: [
        "enabled", "topCell", "backendID", "corners", "inputs", "output", "options"
    ])
    func decodeRejectsMissingRequiredTopLevelField(_ field: String) throws {
        let encoded = try JSONEncoder().encode(PEXProjectConfig())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: field)
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PEXProjectConfig.self, from: data)
        }
    }

    @Test func decodeRejectsMissingRequiredNestedField() throws {
        let encoded = try JSONEncoder().encode(PEXProjectConfig())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var inputs = try #require(object["inputs"] as? [String: Any])
        inputs.removeValue(forKey: "technologyByCorner")
        object["inputs"] = inputs
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PEXProjectConfig.self, from: data)
        }
    }

    @Test func decodeRejectsMissingVersion() {
        let data = Data(#"{"topCell":"INVERTER"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PEXProjectConfig.self, from: data)
        }
    }

    @Test func decodeRejectsUnsupportedVersion() {
        let data = Data(#"{"version":2,"topCell":"INVERTER"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PEXProjectConfig.self, from: data)
        }
    }

    @Test func defaultValues() {
        let config = PEXProjectConfig()
        #expect(config.version == 1)
        #expect(config.enabled == true)
        #expect(config.topCell == "TOP")
        #expect(config.backendID == "")
        #expect(config.inputs.layout == "top.oas")
        #expect(config.options.includeCouplingCaps == true)
    }

    @Test func normalizedCornersFiltersEmpty() {
        var config = PEXProjectConfig()
        config.corners = ["tt", "", "  ", "ss"]
        let normalized = config.normalizedCorners
        #expect(normalized == ["tt", "ss"])
    }

    @Test func normalizedCornersDefaultFallback() {
        var config = PEXProjectConfig()
        config.corners = []
        #expect(config.normalizedCorners == ["tt_25c_1v0"])
    }

    @Test func codableRoundTrip() throws {
        let config = PEXProjectConfig(
            topCell: "TEST",
            backendID: "calibre",
            processProfile: PEXProcessProfileReference(
                profileID: "profile.test",
                pdkID: "pdk.test",
                source: "profiles/profile.test.json",
                requirementID: "extractor",
                pdkRoot: "/tmp/pdk",
                primaryDeckPath: "/tmp/pdk/extractor.deck"
            ),
            corners: ["ff_0c_1v1"]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(PEXProjectConfig.self, from: data)
        #expect(decoded.topCell == "TEST")
        #expect(decoded.backendID == "calibre")
        #expect(decoded.processProfile?.profileID == "profile.test")
        #expect(decoded.processProfile?.primaryDeckPath == "/tmp/pdk/extractor.deck")
        #expect(decoded.corners == ["ff_0c_1v1"])
    }
}
