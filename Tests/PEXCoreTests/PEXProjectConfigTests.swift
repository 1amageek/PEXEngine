import Testing
import Foundation
@testable import PEXCore

@Suite("PEXProjectConfig Tests")
struct PEXProjectConfigTests {
    @Test func decodeFromJSON() throws {
        let json = """
        {
            "topCell": "INVERTER",
            "backendID": "mock",
            "corners": ["tt_25c_1v0", "ss_125c_0v81"]
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

    @Test func defaultValues() {
        let config = PEXProjectConfig()
        #expect(config.version == 1)
        #expect(config.enabled == true)
        #expect(config.topCell == "TOP")
        #expect(config.backendID == "mock")
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
            corners: ["ff_0c_1v1"]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(PEXProjectConfig.self, from: data)
        #expect(decoded.topCell == "TEST")
        #expect(decoded.backendID == "calibre")
        #expect(decoded.corners == ["ff_0c_1v1"])
    }
}
