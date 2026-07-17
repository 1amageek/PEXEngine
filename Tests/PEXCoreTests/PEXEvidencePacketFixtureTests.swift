import Foundation
import Testing
@testable import PEXCore

@Suite("PEX evidence packet fixture")
struct PEXEvidencePacketFixtureTests {
    @Test func currentFixtureDecodesAndRoundTrips() throws {
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "pex-evidence-packet-v2", withExtension: "json")
        )
        let packet = try JSONDecoder().decode(
            PEXEvidencePacket.self,
            from: Data(contentsOf: fixtureURL)
        )

        #expect(packet.schemaVersion == PEXEvidencePacket.currentSchemaVersion)
        #expect(!packet.inputs.isEmpty)
        #expect(!packet.diagnostics.isEmpty)
        #expect(!packet.failureClassifications.isEmpty)
        #expect(!packet.relatedEvidenceIDs.isEmpty)

        let encoded = try JSONEncoder().encode(packet)
        let roundTripped = try JSONDecoder().decode(PEXEvidencePacket.self, from: encoded)
        #expect(roundTripped == packet)
    }
}
