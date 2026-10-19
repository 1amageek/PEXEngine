import Foundation
import Testing
import PEXCore

@Suite("Native configuration kind identity", .timeLimit(.minutes(1)))
struct PEXNativeConfigurationKindTests {
    @Test func legacyJSONDefaultsToMaskAndUnknownKindFails() throws {
        let input = try PEXNativeInputReference(configurationURL: URL(filePath: "/first/config.json"), calibrations: [])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        object.removeValue(forKey: "configurationKind")
        let decoded = try JSONDecoder().decode(PEXNativeInputReference.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == input)
        object["configurationKind"] = "unknown"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PEXNativeInputReference.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func routedKindSurvivesDecodeAndLocationReplacement() throws {
        let input = try PEXNativeInputReference(configurationURL: URL(filePath: "/first/config.json"), calibrations: [],
            configurationKind: .routedOpenRCXV1)
        let decoded = try JSONDecoder().decode(PEXNativeInputReference.self, from: JSONEncoder().encode(input))
        let moved = try decoded.replacingLocations(configurationURL: URL(filePath: "/second/config.json"), calibrations: [])
        #expect(decoded == input)
        #expect(moved.configurationKind == .routedOpenRCXV1)
        #expect(moved.maximumConfigurationBytes == input.maximumConfigurationBytes)
    }

    @Test func lawChangesHashAndRelocationPreservesIt() throws {
        func request(_ input: PEXNativeInputReference) -> PEXRunRequest {
            .init(layoutURL: URL(filePath: "/layout.def"), layoutFormat: .def,
                  sourceNetlistURL: URL(filePath: "/source.sp"), sourceNetlistFormat: .spice,
                  topCell: "TOP", corners: [.init(id: "nominal")],
                  technology: .inline(.init(processName: "test", stack: [], logicalToPhysicalLayerMap: [:],
                      vias: [], defaultExtractionRules: .default, backendHints: [:])),
                  nativeInput: input, backendSelection: .mock(), options: .default)
        }
        let mask = try PEXNativeInputReference(configurationURL: URL(filePath: "/first/config"), calibrations: [])
        let routed = try PEXNativeInputReference(configurationURL: mask.configurationURL, calibrations: [], configurationKind: .routedOpenRCXV1)
        let moved = try routed.replacingLocations(configurationURL: URL(filePath: "/second/config"), calibrations: [])
        #expect(try PEXRequestHash.compute(for: request(mask), inputArtifacts: []) != PEXRequestHash.compute(for: request(routed), inputArtifacts: []))
        #expect(try PEXRequestHash.compute(for: request(routed), inputArtifacts: []) == PEXRequestHash.compute(for: request(moved), inputArtifacts: []))
    }
}
