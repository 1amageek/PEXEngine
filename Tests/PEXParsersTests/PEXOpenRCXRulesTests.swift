import Foundation
import CircuiteFoundation
import PEXCore
import PEXParsers
import Testing

@Suite("Original OpenRCX source compilation", .timeLimit(.minutes(1)))
struct PEXOpenRCXRulesTests {
    typealias Model = PEXOpenRCXSourceModel
    private let compiler = PEXOpenRCXSourceCompiler()
    private let limits = PEXOpenRCXCompilationLimits(maximumSourceBytes: 100_000, maximumLineBytes: 1024,
        maximumLines: 2000, maximumRecords: 2000, maximumRows: 1300, maximumWorkVisits: 2_000_000)
    private struct Provenance: Decodable {
        struct Source: Decodable {
            let corner: String
            let rulesFile: String
            let rulesSHA256: String
            let rulesByteCount: UInt64
            let technologyLEFSHA256: String
            let technologyLEFByteCount: UInt64
        }
        let openPDKsRevision: String
        let sources: [Source]
    }

    private func fixture(_ corner: Model.RCCorner = .nominal) throws -> (Data, Model.Selection) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/OpenRCXRules")
        let provenance = try JSONDecoder().decode(Provenance.self, from: Data(contentsOf: root.appending(path: "provenance.json")))
        #expect(provenance.openPDKsRevision == "c6d73a35f524070e85faff4a6a9eef49553ebc2b")
        let source = try #require(provenance.sources.first { $0.corner == corner.rawValue })
        let bytes = try Data(contentsOf: root.appending(path: source.rulesFile))
        let rules = try ArtifactID(digest: ContentDigest(algorithm: .sha256, hexadecimalValue: source.rulesSHA256), byteCount: source.rulesByteCount)
        let tech = try ArtifactID(digest: ContentDigest(algorithm: .sha256, hexadecimalValue: source.technologyLEFSHA256), byteCount: source.technologyLEFByteCount)
        return (bytes, .init(processName: "sky130A", corner: corner, rulesArtifactID: rules,
            technologyLEFArtifactID: tech, routingLayerNames: ["li1", "met1", "met2", "met3", "met4", "met5"]))
    }

    private func selection(for bytes: Data, replacing old: Model.Selection) throws -> Model.Selection {
        let id = try ArtifactID(digest: ContentDigest(algorithm: .sha256,
            hexadecimalValue: PEXRequestHash.compute(from: bytes).value), byteCount: UInt64(bytes.count))
        return .init(processName: old.processName, corner: old.corner, rulesArtifactID: id,
                     technologyLEFArtifactID: old.technologyLEFArtifactID, routingLayerNames: old.routingLayerNames)
    }

    private func compile(_ corner: Model.RCCorner = .nominal) throws -> Model {
        let (bytes, selection) = try fixture(corner)
        return try compiler.compile(bytes: bytes, selection: selection, limits: limits)
    }

    @Test(arguments: [Model.RCCorner.nominal, .minimum, .maximum])
    func originalThreeCornerSourcesRetainCompleteTablesAndPinnedBoundary(_ corner: Model.RCCorner) throws {
        let (bytes, selection) = try fixture(corner)
        let model = try compiler.compile(bytes: bytes, selection: selection, limits: limits)
        #expect(model.selection == selection)
        #expect(model.families.count == 28 && model.tables.count == 92)
        #expect(model.tables.reduce(0) { $0 + $1.capacitanceSamples.count + $1.resistanceSamples.count } == 1184)
        #expect(model.families.filter { $0.kind == .over }.map { $0.widthsMicrons[0] } == [0.17, 0.14, 0.14, 0.3, 0.3, 1.6])
        #expect(model.profile.version == 1 && !model.profile.overCell && !model.profile.includesPinCapacitance)
        #expect(model.profile.usesLEFWireResistance && !model.profile.mergeViaResistance)
        #expect(model.profile.contextDepth == 5 && model.profile.lateralContextTracks == 10)
        #expect(model.profile.diagonalContextDepth == 3)
        #expect(model.profile.couplingThresholdFemtofarads == 0 && model.profile.temperatureScaling == "source-unscaled")
        try compiler.validate(model: model, bytes: bytes, limits: limits)
        #expect(try JSONDecoder().decode(Model.self, from: JSONEncoder().encode(model)) == model)
    }

    @Test func distinctResistanceAxesEmptyBlocksAndRawCapacitanceRangeRemainSourceFacts() throws {
        let (bytes, selection) = try fixture()
        let model = try compiler.compile(bytes: bytes, selection: selection, limits: limits)
        let res = try #require(model.tables.first { $0.context == .init(metal: 1, kind: .resOver, underMetal: 0) })
        #expect(res.resistanceSamples[1].firstSpacingMicrons == 0 && res.resistanceSamples[1].secondSpacingMicrons == 0.29)
        #expect(res.resistanceSamples[10].firstSpacingMicrons == 0.29 && res.resistanceSamples[10].secondSpacingMicrons == 0.29)
        #expect(res.resistanceSamples[0].resistanceOhmsPerNanometer == 0.0684492)
        #expect(res.capacitanceSamples.isEmpty)
        let cap = try #require(model.tables.first { $0.context == .init(metal: 1, kind: .over, underMetal: 0) })
        let row = try #require(cap.capacitanceSamples.first)
        #expect(row.distanceMicrons == 0.17 && row.couplingFemtofaradsPerNanometer == 7.95044e-05)
        #expect(row.fringeFemtofaradsPerNanometer == 1.24225e-05 && row.resistanceOhmsPerNanometer == 0.0342246)
        #expect(String(decoding: bytes[row.sourceRange.lowerBound..<row.sourceRange.upperBound], as: UTF8.self)
                == "0.17 7.95044e-05 1.24225e-05 0.0342246")
        for context in [Model.Context(metal: 2, kind: .resOver, underMetal: 1), .init(metal: 1, kind: .diagUnder, overMetal: 6)] {
            let table = try #require(model.tables.first { $0.context == context })
            #expect(table.isEmpty && table.capacitanceSamples.isEmpty && table.resistanceSamples.isEmpty)
        }
        #expect(!model.tables.contains { $0.context == .init(metal: 1, kind: .over, underMetal: 1) })
    }

    @Test func sourceReplayRejectsPlausibleModelForgeryAndChangesDomainIdentity() throws {
        let (bytes, selection) = try fixture()
        let original = try compiler.compile(bytes: bytes, selection: selection, limits: limits)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var tables = try #require(json["tables"] as? [[String: Any]])
        let index = try #require(tables.firstIndex { ($0["capacitanceSamples"] as? [Any])?.isEmpty == false })
        var rows = try #require(tables[index]["capacitanceSamples"] as? [[String: Any]])
        rows[0]["couplingFemtofaradsPerNanometer"] = 0.1
        tables[index]["capacitanceSamples"] = rows; json["tables"] = tables
        let forged = try JSONDecoder().decode(Model.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(try forged.domainDigest() != original.domainDigest())
        #expect(throws: PEXOpenRCXSourceError.modelMismatch) { try compiler.validate(model: forged, bytes: bytes, limits: limits) }
        json["profile"] = "unpinned-new-law"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Model.self, from: JSONSerialization.data(withJSONObject: json)) }
    }

    @Test func sourceIdentityMismatchNeverCompilesAnAlteredOrTruncatedArtifact() throws {
        let (bytes, selection) = try fixture()
        var changed = bytes; changed[0] = 65
        #expect(throws: PEXOpenRCXSourceError.sourceMismatch) { try compiler.compile(bytes: changed, selection: selection, limits: limits) }
        let truncated = Data(bytes.dropLast())
        #expect(throws: PEXOpenRCXSourceError.sourceMismatch) { try compiler.compile(bytes: truncated, selection: selection, limits: limits) }
    }

    @Test func malformedCompleteSourcesCannotHideCountDomainOrContextLoss() throws {
        let (bytes, old) = try fixture()
        let source = String(decoding: bytes, as: UTF8.self)
        let changes = [
            ("DIAGMODEL ON", "DIAGMODEL OFF"), ("LayerCount 6", "LayerCount 7"),
            ("DensityRate 1  0", "DensityRate 2  0"), ("DIST count 55 width 0.17", "DIST count 54 width 0.17"),
            ("WIDTH Table 1 entries:  0.17", "WIDTH Table 1 entries:  0.18"),
            ("0.17 7.95044e-05", "0.17 nan"), ("Metal 1 OVER 0", "Metal 1 OVER 1"),
            ("0.34 4.94413e-05", "0.17 4.94413e-05")
        ]
        for (before, after) in changes {
            #expect(source.contains(before))
            let modified = Data(source.replacingOccurrences(of: before, with: after).utf8)
            let selection = try selection(for: modified, replacing: old)
            #expect(throws: PEXOpenRCXSourceError.self) { try compiler.compile(bytes: modified, selection: selection, limits: limits) }
        }
        let trailing = Data((source + "Unknown value\n").utf8)
        let selection = try selection(for: trailing, replacing: old)
        #expect(throws: PEXOpenRCXSourceError.self) { try compiler.compile(bytes: trailing, selection: selection, limits: limits) }
    }

    @Test func invalidDecodedInventoryOrRangeFailsBeforeNumericalConsumption() throws {
        let model = try compile()
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        for change in 0..<3 {
            var json = original
            if change == 0 {
                var tables = try #require(json["tables"] as? [[String: Any]]); tables.removeLast(); json["tables"] = tables
            } else if change == 1 {
                var tables = try #require(json["tables"] as? [[String: Any]])
                tables[1] = tables[0]; json["tables"] = tables
            } else {
                json["sourceHeaderRange"] = ["lowerBound": 0, "upperBound": Int(model.selection.rulesArtifactID.byteCount) + 1]
            }
            #expect(throws: PEXOpenRCXSourceError.self) { try JSONDecoder().decode(Model.self, from: JSONSerialization.data(withJSONObject: json)) }
        }
    }

    @Test func everyCallerQuotaAndMidScanCancellationRefusesWithoutPartialModel() throws {
        let (bytes, selection) = try fixture()
        for resource in [PEXOpenRCXSourceError.Resource.sourceBytes, .lineBytes, .lines, .records, .rows, .workVisits] {
            let limited = PEXOpenRCXCompilationLimits(maximumSourceBytes: resource == .sourceBytes ? 1 : limits.maximumSourceBytes,
                maximumLineBytes: resource == .lineBytes ? 1 : limits.maximumLineBytes,
                maximumLines: resource == .lines ? 1 : limits.maximumLines,
                maximumRecords: resource == .records ? 0 : limits.maximumRecords,
                maximumRows: resource == .rows ? 0 : limits.maximumRows,
                maximumWorkVisits: resource == .workVisits ? 0 : limits.maximumWorkVisits)
            #expect(throws: PEXOpenRCXSourceError.limitExceeded(resource)) { try compiler.compile(bytes: bytes, selection: selection, limits: limited) }
        }
        #expect(throws: PEXOpenRCXSourceError.cancelled) { try compiler.compile(bytes: bytes, selection: selection, limits: limits, isCancelled: { true }) }
        var checks = 0
        #expect(throws: PEXOpenRCXSourceError.cancelled) {
            try compiler.compile(bytes: bytes, selection: selection, limits: limits, isCancelled: { checks += 1; return checks == 1000 })
        }
        #expect(checks == 1000)
    }
}
