import Foundation
import Testing
import CircuiteFoundation
import LEF
import PEXCore
@testable import PEXAdapters

@Suite("Exact corner LEF ground calibration projection", .timeLimit(.minutes(1)))
struct NativeRoutedPEXGroundSourceTests {
    private let names = ["li1", "met1", "met2", "met3", "met4", "met5"]

    private func source(_ text: String) throws -> NativeRoutedPEXDecodedLEF {
        let bytes = Data(text.utf8)
        let reference = try ArtifactReference(digest: .init(algorithm: .sha256,
            hexadecimalValue: PEXRequestHash.compute(from: bytes).value), byteCount: UInt64(bytes.count),
            descriptor: .init(role: .input, kind: .technology, format: .lef))
        return .init(document: try LEFLibraryReader.read(bytes), reference: reference)
    }
    private func selection(_ source: NativeRoutedPEXDecodedLEF,
                           names: [String]? = nil) -> PEXOpenRCXSourceModel.Selection {
        .init(processName: "explicit-source-test", corner: .nominal,
            rulesArtifactID: source.reference.id, technologyLEFArtifactID: source.reference.id,
            routingLayerNames: names ?? self.names)
    }
    private func budget(work: Int = 100000, records: Int = 1000) -> NativeRoutedPEXPreparationBudget {
        .init(limits: .init(maximumSourceBytes: 16000000, maximumTotalSourceBytes: 64000000,
            maximumRecords: records, maximumStringBytes: 10000, maximumWorkVisits: work,
            maximumNetlistManagedStorageBytes: 64000000, maximumNetlistAllocationBytes: 128000000))
    }
    private func project(_ source: NativeRoutedPEXDecodedLEF) throws -> PEXRoutedGroundCapacitanceModel {
        var budget = budget()
        return try NativeRoutedPEXGroundSourceProjection.project(technology: source, selection: selection(source),
            cornerID: "nominal", budget: &budget, isCancelled: { false })
    }

    @Test func decodedValuesAndWholeSourceRangesRemainExactWithoutThicknessDefault() throws {
        let source = try source(RoutedPreparationFixture.technology(full: true))
        let model = try project(source)
        #expect(model.algorithm == .lefAreaBoundaryV1)
        #expect(model.selection == selection(source))
        #expect(model.capacitanceUnitPicofarads == 1 && model.layers.map(\.name) == names)
        #expect(model.layers.allSatisfy { $0.areaPicofaradsPerSquareMicron == 0.0001
            && $0.edgePicofaradsPerMicron == 0.0002 && $0.thicknessMicrons == 0.3 })
        #expect(model.unitSourceRanges == [.init(lowerBound: 0, upperBound: Int(source.reference.byteCount))])
        #expect(model.layers.allSatisfy { $0.sourceRanges == model.unitSourceRanges })
        let absent = try self.source(RoutedPreparationFixture.technology(full: true)
            .replacingOccurrences(of: "THICKNESS 0.3 ;", with: ""))
        let absentModel = try project(absent)
        #expect(absentModel.layers.allSatisfy { $0.thicknessMicrons == nil })
    }

    @Test func absentAndInvalidCalibrationNeverInheritNominalOrZero() throws {
        let text = RoutedPreparationFixture.technology(full: true)
        for changed in [
            text.replacingOccurrences(of: "CAPACITANCE PICOFARADS 1 ;", with: ""),
            text.replacingOccurrences(of: "CAPACITANCE PICOFARADS 1 ;", with: "CAPACITANCE PICOFARADS 1000 ;"),
            text.replacingOccurrences(of: "CAPACITANCE CPERSQDIST 0.0001 ;", with: ""),
            text.replacingOccurrences(of: "EDGECAPACITANCE 0.0002 ;", with: ""),
            text.replacingOccurrences(of: "EDGECAPACITANCE 0.0002 ;", with: "EDGECAPACITANCE 0 ;"),
            text.replacingOccurrences(of: "THICKNESS 0.3 ;", with: "THICKNESS 0 ;")
        ] {
            let source = try source(changed)
            #expect(throws: NativeRoutedPEXPreparationError.self) { _ = try project(source) }
        }
    }

    @Test func sourceIdentityOrderAndAmbiguityAreChecked() throws {
        let original = try source(RoutedPreparationFixture.technology(full: true))
        let foreign = try source(RoutedPreparationFixture.technology(full: true, resistance: "25.6"))
        var budget = budget()
        #expect(throws: NativeRoutedPEXPreparationError.sourceMismatch("Ground calibration requires the exact selected corner technology")) {
            _ = try NativeRoutedPEXGroundSourceProjection.project(technology: original, selection: selection(foreign),
                cornerID: "nominal", budget: &budget, isCancelled: { false })
        }
        var repeated = original.document
        repeated.layers.append(try #require(repeated.layers.first { $0.name == "li1" }))
        let ambiguous = NativeRoutedPEXDecodedLEF(document: repeated, reference: original.reference)
        #expect(throws: NativeRoutedPEXPreparationError.self) { _ = try project(ambiguous) }
        var orderedBudget = self.budget()
        let reversed = try NativeRoutedPEXGroundSourceProjection.project(technology: original,
            selection: selection(original, names: Array(names.reversed())), cornerID: "nominal",
            budget: &orderedBudget, isCancelled: { false })
        #expect(reversed.layers.map(\.name) == Array(names.reversed()))
    }

    @Test func sourceProjectionUsesOneFiniteBudgetAndPreservesCancellation() throws {
        let source = try source(RoutedPreparationFixture.technology(full: true))
        var work = budget(work: 1)
        #expect(throws: NativeRoutedPEXPreparationError.limitExceeded("workVisits")) {
            _ = try NativeRoutedPEXGroundSourceProjection.project(technology: source, selection: selection(source),
                cornerID: "nominal", budget: &work, isCancelled: { false })
        }
        var records = budget(records: 1)
        #expect(throws: NativeRoutedPEXPreparationError.limitExceeded("records")) {
            _ = try NativeRoutedPEXGroundSourceProjection.project(technology: source, selection: selection(source),
                cornerID: "nominal", budget: &records, isCancelled: { false })
        }
        var cancelled = budget()
        #expect(throws: NativeRoutedPEXPreparationError.cancelled) {
            _ = try NativeRoutedPEXGroundSourceProjection.project(technology: source, selection: selection(source),
                cornerID: "nominal", budget: &cancelled, isCancelled: { true })
        }
    }

    @Test func threeOriginalCornerTechnologiesRetainIndependentExactSourceFacts() throws {
        struct Provenance: Decodable {
            struct Source: Decodable {
                let corner: String
                let rulesSHA256: String
                let rulesByteCount: UInt64
                let technologyLEFOriginalPath: String
                let technologyLEFSHA256: String
                let technologyLEFByteCount: UInt64
            }
            let sources: [Source]
        }
        let provenanceURL = try #require(Bundle.module.url(forResource: "provenance", withExtension: "json", subdirectory: "OpenRCXRules"))
        let provenance = try JSONDecoder().decode(Provenance.self, from: Data(contentsOf: provenanceURL))
        #expect(Set(provenance.sources.map(\.corner)) == Set(["nom", "min", "max"]))
        var references = Set<ArtifactID>()
        for row in provenance.sources {
            let url = URL(fileURLWithPath: row.technologyLEFOriginalPath)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = try #require(attributes[.size] as? NSNumber)
            try #require(size.uint64Value == row.technologyLEFByteCount && size.uint64Value <= 16000000)
            let bytes = try Data(contentsOf: url)
            try #require(PEXRequestHash.compute(from: bytes).value == row.technologyLEFSHA256)
            let technology = try ArtifactReference(digest: .init(algorithm: .sha256,
                hexadecimalValue: row.technologyLEFSHA256), byteCount: row.technologyLEFByteCount,
                descriptor: .init(role: .input, kind: .technology, format: .raw))
            let rules = try ArtifactID(digest: .init(algorithm: .sha256, hexadecimalValue: row.rulesSHA256), byteCount: row.rulesByteCount)
            let document = try LEFLibraryReader.read(bytes)
            let source = NativeRoutedPEXDecodedLEF(document: document, reference: technology)
            let corner = try #require(PEXOpenRCXSourceModel.RCCorner(rawValue: row.corner))
            let selected = PEXOpenRCXSourceModel.Selection(processName: "sky130A", corner: corner,
                rulesArtifactID: rules, technologyLEFArtifactID: technology.id, routingLayerNames: names)
            var budget = budget()
            let model = try NativeRoutedPEXGroundSourceProjection.project(technology: source, selection: selected,
                cornerID: .init(row.corner), budget: &budget, isCancelled: { false })
            #expect(model.selection == selected && model.cornerID == .init(row.corner))
            #expect(model.capacitanceUnitPicofarads == document.unitDeclarations.capacitancePicofarads)
            for (index, name) in names.enumerated() {
                let decoded = try #require(document.layers.first { $0.name == name })
                #expect(model.layers[index].areaPicofaradsPerSquareMicron == decoded.capacitance)
                #expect(model.layers[index].edgePicofaradsPerMicron == decoded.edgeCapacitance)
                #expect(model.layers[index].thicknessMicrons == decoded.thickness)
            }
            references.insert(technology.id)
        }
        #expect(references.count == 3)
    }
}
