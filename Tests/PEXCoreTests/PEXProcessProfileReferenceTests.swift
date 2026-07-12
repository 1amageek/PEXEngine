import Foundation
import Testing
@testable import PEXCore

@Suite("PEX Process Profile Reference Tests")
struct PEXProcessProfileReferenceTests {
    @Test func cornerDeckPathsRoundTripWithoutPrimaryDeck() throws {
        let profile = PEXProcessProfileReference(
            profileID: "sky130.signoff",
            pdkID: "sky130A",
            cornerDeckPaths: [
                "tt": "/pdk/magic/tt.magicrc",
                "ss": "/pdk/magic/ss.magicrc",
            ]
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(PEXProcessProfileReference.self, from: data)
        #expect(decoded.cornerDeckPaths == profile.cornerDeckPaths)
        #expect(decoded.deckPath(for: PEXCornerID("tt")) == "/pdk/magic/tt.magicrc")
        #expect(decoded.primaryDeckPath == nil)
    }

    @Test func emptyCornerDeckEntriesAreDropped() {
        let profile = PEXProcessProfileReference(
            cornerDeckPaths: ["": "", "tt": " /pdk/tt.magicrc "]
        )
        #expect(profile.cornerDeckPaths == ["tt": "/pdk/tt.magicrc"])
    }
}
