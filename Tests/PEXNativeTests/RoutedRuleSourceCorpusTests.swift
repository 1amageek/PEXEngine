import Foundation
import CircuiteFoundation
import PEXCore
import PEXNative
import PEXParsers
import Testing

@Suite("Original Sky130 three-corner rule numerical queries", .timeLimit(.minutes(1)))
struct RoutedRuleSourceCorpusTests {
    private struct Provenance: Decodable {
        struct Source: Decodable {
            let corner: String
            let rulesFile: String
            let rulesSHA256: String
            let rulesByteCount: UInt64
            let technologyLEFSHA256: String
            let technologyLEFByteCount: UInt64
        }
        let sources: [Source]
    }

    @Test(arguments: ["nom", "min", "max"])
    func compilerToPreparedNumericalQueryUsesOriginalCornerBytes(corner: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "PEXParsersTests/Fixtures/OpenRCXRules")
        let provenance = try JSONDecoder().decode(Provenance.self, from: Data(contentsOf: root.appending(path: "provenance.json")))
        let source = try #require(provenance.sources.first { $0.corner == corner })
        let selection = PEXOpenRCXSourceModel.Selection(processName: "sky130A", corner: try #require(PEXOpenRCXSourceModel.RCCorner(rawValue: corner)),
            rulesArtifactID: try .init(digest: .init(algorithm: .sha256, hexadecimalValue: source.rulesSHA256), byteCount: source.rulesByteCount),
            technologyLEFArtifactID: try .init(digest: .init(algorithm: .sha256, hexadecimalValue: source.technologyLEFSHA256), byteCount: source.technologyLEFByteCount),
            routingLayerNames: ["li1", "met1", "met2", "met3", "met4", "met5"])
        let bytes = try Data(contentsOf: root.appending(path: source.rulesFile))
        let compiler = PEXOpenRCXSourceCompiler()
        let model = try compiler.compile(bytes: bytes, selection: selection,
            limits: .init(maximumSourceBytes: 100_000, maximumLineBytes: 1000, maximumLines: 5000,
                maximumRecords: 5000, maximumRows: 4000, maximumWorkVisits: 1_000_000), isCancelled: { false })
        let evaluator = try PinnedOpenRCXRuleEvaluator(model: model, databaseUnitsPerMicron: 1000, isCancelled: { false })
        let over = PEXOpenRCXSourceModel.Context(metal: 2, kind: .over, underMetal: 0)
        let first = try evaluator.evaluate(context: over, widthDatabaseUnits: 230, distance: .finite(databaseUnits: 0), isCancelled: { false })
        let open = try evaluator.evaluate(context: over, widthDatabaseUnits: 230, distance: .open, isCancelled: { false })
        let diagonal = try evaluator.evaluate(context: .init(metal: 2, kind: .diagUnder, overMetal: 3),
            widthDatabaseUnits: 230, distance: .finite(databaseUnits: 0), isCancelled: { false })
        let expected: (cc: Double, fringe: Double, diagonal: Double)
        switch corner {
        case "nom": expected = (0.000105491, 4.66363e-05, 3.87724e-05)
        case "min": expected = (9.12556e-05, 4.33544e-05, 3.14106e-05)
        default: expected = (9.88048e-05, 4.89214e-05, 6.40976e-05)
        }
        #expect(first.selectedWidthMicrons == 0.14)
        #expect(abs(first.couplingFaradsPerDatabaseUnit - expected.cc * 1e-15) < 1e-30)
        #expect(abs(open.fringeFaradsPerDatabaseUnit - expected.fringe * 1e-15) < 1e-30)
        #expect(abs(diagonal.physicalCouplingFaradsPerDatabaseUnit - expected.diagonal * 1e-15) < 1e-30)
        let firstRange = try #require(first.sampleSourceRanges.first)
        #expect(String(decoding: bytes[firstRange.lowerBound..<firstRange.upperBound], as: UTF8.self).hasPrefix("0.14 "))
        #expect(String(decoding: bytes[first.tableSourceRange.lowerBound..<first.tableSourceRange.upperBound], as: UTF8.self).hasPrefix("Metal 2 OVER 0"))
        #expect(throws: NativeRoutedRuleError.emptyActiveTable) {
            try evaluator.evaluate(context: .init(metal: 1, kind: .diagUnder, overMetal: 6),
                widthDatabaseUnits: 170, distance: .finite(databaseUnits: 0), isCancelled: { false })
        }
        // Original rule/compiler intake is exercised. Matching LEF resistance and
        // routed geometry/source binding remain separate integration evidence.
    }
}
