import Foundation
import Testing
import PEXTestSupport
@testable import PEXCore

@Suite("PEX Request Hash Tests")
struct PEXRequestHashTests {
    @Test func processProfileDeckContentParticipatesInRequestHash() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pex_hash_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove temporary hash fixture: \(error)")
            }
        }
        let deck = directory.appending(path: "magic.rc")
        try Data("deck-v1".utf8).write(to: deck)
        let request = PEXRunRequest(
            layoutURL: URL(filePath: "/tmp/layout.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/netlist.cir"),
            sourceNetlistFormat: .spice,
            topCell: "TOP",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(TechnologyIR(
                processName: "test",
                stack: [],
                logicalToPhysicalLayerMap: [:],
                vias: [],
                defaultExtractionRules: .default,
                backendHints: [:]
            )),
            processProfile: PEXProcessProfileReference(primaryDeckPath: deck.path(percentEncoded: false)),
            backendSelection: .mock(),
            options: .default
        )

        let first = try PEXRequestHash.compute(for: request, inputArtifacts: [])
        try Data("deck-v2".utf8).write(to: deck)
        let second = try PEXRequestHash.compute(for: request, inputArtifacts: [])
        #expect(first != second)
    }

    @Test func everyCornerDeckContentParticipatesInRequestHash() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pex_corner_hash_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                Issue.record("Failed to remove temporary corner hash fixture: \(error)")
            }
        }
        let ttDeck = directory.appending(path: "tt.magicrc")
        let ssDeck = directory.appending(path: "ss.magicrc")
        try Data("tt-v1".utf8).write(to: ttDeck)
        try Data("ss-v1".utf8).write(to: ssDeck)
        let request = PEXRunRequest(
            layoutURL: URL(filePath: "/tmp/layout.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/netlist.cir"),
            sourceNetlistFormat: .spice,
            topCell: "TOP",
            corners: [PEXCorner(id: "tt"), PEXCorner(id: "ss")],
            technology: .inline(TechnologyIR(
                processName: "test",
                stack: [],
                logicalToPhysicalLayerMap: [:],
                vias: [],
                defaultExtractionRules: .default,
                backendHints: [:]
            )),
            processProfile: PEXProcessProfileReference(cornerDeckPaths: [
                "tt": ttDeck.path(percentEncoded: false),
                "ss": ssDeck.path(percentEncoded: false),
            ]),
            backendSelection: .mock(),
            options: .default
        )

        let first = try PEXRequestHash.compute(for: request, inputArtifacts: [])
        try Data("ss-v2".utf8).write(to: ssDeck)
        let second = try PEXRequestHash.compute(for: request, inputArtifacts: [])
        #expect(first != second)
    }

    @Test func processFileRelocationPreservesIdentityAndViewChangesInvalidateIt() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pex_role_hash_\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Failed to remove role hash fixture: \(error)") }
        }
        let first = directory.appending(path: "first.rc")
        let second = directory.appending(path: "second.rc")
        let firstView = directory.appending(path: "first.lef")
        let secondView = directory.appending(path: "second.lef")
        for url in [first, second] { try Data("same rules".utf8).write(to: url) }
        for url in [firstView, secondView] { try Data("same view".utf8).write(to: url) }
        func request(deck: URL, view: URL) -> PEXRunRequest {
            PEXRunRequest(
                layoutURL: URL(filePath: "/tmp/layout.gds"), layoutFormat: .gds,
                sourceNetlistURL: URL(filePath: "/tmp/netlist.sp"), sourceNetlistFormat: .spice,
                topCell: "TOP", corners: [PEXCorner(id: "tt")],
                technology: .inline(TechnologyIR(processName: "test", stack: [], logicalToPhysicalLayerMap: [:],
                                               vias: [], defaultExtractionRules: .default, backendHints: [:])),
                processProfile: PEXProcessProfileReference(profileID: "process", primaryDeckPath: deck.path,
                                cornerDeckPaths: ["tt": deck.path], requiredViewPaths: ["technologyLEF": view.path]),
                backendSelection: .mock(), options: .default
            )
        }
        let original = try PEXRequestHash.compute(for: request(deck: first, view: firstView), inputArtifacts: [])
        let relocated = try PEXRequestHash.compute(for: request(deck: second, view: secondView), inputArtifacts: [])
        #expect(original == relocated)
        try Data("changed view".utf8).write(to: secondView)
        #expect(try PEXRequestHash.compute(for: request(deck: second, view: secondView), inputArtifacts: []) != original)
    }

    @Test func perCornerTechnologyParticipatesInRequestHash() throws {
        let base = TechnologyIR(
            processName: "base",
            stack: [],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )
        let firstCornerTechnology = TechnologyIR(
            processName: "corner-a",
            stack: [],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )
        let secondCornerTechnology = TechnologyIR(
            processName: "corner-b",
            stack: [],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )
        let request = PEXRunRequest(
            layoutURL: URL(filePath: "/tmp/layout.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/netlist.cir"),
            sourceNetlistFormat: .spice,
            topCell: "TOP",
            corners: [PEXCorner(id: "tt"), PEXCorner(id: "ss")],
            technology: .inline(base),
            technologyByCorner: ["ss": .inline(firstCornerTechnology)],
            backendSelection: .mock(),
            options: .default
        )
        let changed = PEXRunRequest(
            layoutURL: request.layoutURL,
            layoutFormat: request.layoutFormat,
            sourceNetlistURL: request.sourceNetlistURL,
            sourceNetlistFormat: request.sourceNetlistFormat,
            topCell: request.topCell,
            corners: request.corners,
            technology: request.technology,
            technologyByCorner: ["ss": .inline(secondCornerTechnology)],
            backendSelection: request.backendSelection,
            options: request.options
        )

        let firstHash = try PEXRequestHash.compute(for: request, inputArtifacts: [])
        let secondHash = try PEXRequestHash.compute(for: changed, inputArtifacts: [])
        #expect(firstHash != secondHash)
    }

    @Test func JSONTechnologyAbsolutePathsDoNotParticipateInRequestHash() throws {
        let first = PEXRunRequest(
            layoutURL: URL(filePath: "/tmp/layout.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/netlist.cir"),
            sourceNetlistFormat: .spice,
            topCell: "TOP",
            corners: [PEXCorner(id: "tt"), PEXCorner(id: "ss")],
            technology: .jsonFile(URL(filePath: "/one/technology.json")),
            technologyByCorner: ["ss": .jsonFile(URL(filePath: "/one/ss.json"))],
            backendSelection: .mock(),
            options: .default
        )
        let second = PEXRunRequest(
            layoutURL: first.layoutURL,
            layoutFormat: first.layoutFormat,
            sourceNetlistURL: first.sourceNetlistURL,
            sourceNetlistFormat: first.sourceNetlistFormat,
            topCell: first.topCell,
            corners: first.corners,
            technology: .jsonFile(URL(filePath: "/two/technology.json")),
            technologyByCorner: ["ss": .jsonFile(URL(filePath: "/two/ss.json"))],
            backendSelection: first.backendSelection,
            options: first.options
        )

        let firstHash = try PEXRequestHash.compute(for: first, inputArtifacts: [])
        let secondHash = try PEXRequestHash.compute(for: second, inputArtifacts: [])
        #expect(firstHash == secondHash)
    }
}
