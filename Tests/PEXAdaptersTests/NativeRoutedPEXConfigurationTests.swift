import Foundation
import Testing
import CircuiteFoundation
import PEXCore
import PEXNative
import PEXParsers
@testable import PEXAdapters

@Suite("Routed native source declarations", .timeLimit(.minutes(1)))
struct NativeRoutedPEXConfigurationTests {
    @Test func explicitRCCornerMatrixAndExactSourceReferencesSurviveJSON() throws {
        let fixture = try Fixture()
        let config = fixture.configuration([fixture.corner("slowLogic", .minimum), fixture.corner("hotLogic", .maximum)])
        let decoded = try JSONDecoder().decode(NativeRoutedPEXConfiguration.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
        try decoded.validate(requiredCornerIDs: ["slowLogic", "hotLogic"], processName: "source-process",
                             authorityReferences: [fixture.rules, fixture.technology])
        #expect(decoded.sources.corners[0].selection.corner == .minimum)
        #expect(decoded.sources.corners[1].selection.corner == .maximum)
    }

    @Test func missingDuplicateAndForeignCornersFailWithoutFallback() throws {
        let f = try Fixture()
        #expect(throws: NativeRoutedPEXPreparationError.self) {
            try f.configuration([f.corner("nominal", .nominal)]).validate(requiredCornerIDs: ["minimum"], processName: "source-process")
        }
        #expect(throws: NativeRoutedPEXPreparationError.self) {
            try f.configuration([f.corner("nominal", .nominal), f.corner("nominal", .maximum)]).validate(requiredCornerIDs: ["nominal"], processName: "source-process")
        }
        #expect(throws: NativeRoutedPEXPreparationError.self) {
            try f.configuration([f.corner("nominal", .nominal)]).validate(requiredCornerIDs: ["nominal"], processName: "foreign-process")
        }
    }

    @Test func fullReferenceAuthorityMismatchIsNotAcceptedByContentIDAlone() throws {
        let f = try Fixture()
        let foreign = try ArtifactReference(digest: f.rules.id.digest, byteCount: f.rules.id.byteCount,
            descriptor: .init(role: .output, kind: try ArtifactKind(rawValue: "foreign-authority"), format: .raw))
        #expect(foreign.id == f.rules.id)
        #expect(foreign != f.rules)
        #expect(throws: NativeRoutedPEXPreparationError.self) {
            try f.configuration([f.corner("nominal", .nominal)]).validate(requiredCornerIDs: ["nominal"],
                processName: "source-process", authorityReferences: [foreign])
        }
    }

    @Test func conflictingFullReferencesCannotDisappearDuringContentDeduplication() throws {
        let f = try Fixture()
        let conflicting = try ArtifactReference(digest: f.def.id.digest, byteCount: f.def.id.byteCount,
            descriptor: .init(role: .input, kind: ArtifactKind(rawValue: "different-source-role"), format: .raw))
        let original = f.configuration([f.corner("nominal", .nominal)])
        let invalid = NativeRoutedPEXConfiguration(algorithm: .unionSheetAreaBoundaryV1, sources: .init(expectedDEF: f.def, expectedSourceNetlist: conflicting,
            routedTechnologyLEF: f.technology, standardCellLEFs: [f.library], corners: original.sources.corners),
            maximumCellSpanDatabaseUnits: original.maximumCellSpanDatabaseUnits, extractionLimits: original.extractionLimits, compilationLimits: original.compilationLimits,
            preparationLimits: original.preparationLimits)
        #expect(throws: NativeRoutedPEXPreparationError.self) {
            try invalid.validate(requiredCornerIDs: ["nominal"], processName: "source-process")
        }
    }

    @Test func limitsAndVersionAreAdmissionRequirements() throws {
        let f = try Fixture()
        let config = f.configuration([f.corner("nominal", .nominal)])
        let old = NativeRoutedPEXConfiguration(version: 2, algorithm: .unionSheetAreaBoundaryV1, sources: config.sources, maximumCellSpanDatabaseUnits: config.maximumCellSpanDatabaseUnits, extractionLimits: config.extractionLimits,
            compilationLimits: config.compilationLimits, preparationLimits: config.preparationLimits)
        #expect(throws: NativeRoutedPEXPreparationError.self) {
            try old.validate(requiredCornerIDs: ["nominal"], processName: "source-process")
        }
        let zeroSpan = NativeRoutedPEXConfiguration(algorithm: .unionSheetAreaBoundaryV1, sources: config.sources,
            maximumCellSpanDatabaseUnits: 0, extractionLimits: config.extractionLimits,
            compilationLimits: config.compilationLimits, preparationLimits: config.preparationLimits)
        #expect(throws: NativeRoutedPEXPreparationError.self) {
            try zeroSpan.validate(requiredCornerIDs: ["nominal"], processName: "source-process")
        }
        let encoded = try JSONEncoder().encode(config)
        for missing in ["algorithm", "maximumCellSpanDatabaseUnits"] {
            var incomplete = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            incomplete.removeValue(forKey: missing)
            let bytes = try JSONSerialization.data(withJSONObject: incomplete)
            #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(NativeRoutedPEXConfiguration.self, from: bytes) }
        }
        var legacyJSON = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var missingCaps = try #require(legacyJSON["preparationLimits"] as? [String: Any])
        missingCaps.removeValue(forKey: "maximumNetlistManagedStorageBytes")
        missingCaps.removeValue(forKey: "maximumNetlistAllocationBytes")
        legacyJSON["preparationLimits"] = missingCaps
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(NativeRoutedPEXConfiguration.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        }
        let bounded = NativeRoutedPEXConfiguration(algorithm: .unionSheetAreaBoundaryV1, sources: config.sources, maximumCellSpanDatabaseUnits: config.maximumCellSpanDatabaseUnits, extractionLimits: config.extractionLimits,
            compilationLimits: config.compilationLimits,
            preparationLimits: .init(maximumSourceBytes: 10000, maximumTotalSourceBytes: 100000, maximumRecords: 100, maximumStringBytes: 1000, maximumWorkVisits: 1, maximumNetlistManagedStorageBytes: 64000000, maximumNetlistAllocationBytes: 128000000))
        #expect(throws: NativeRoutedPEXPreparationError.limitExceeded("workVisits")) {
            try bounded.validate(requiredCornerIDs: ["nominal"], processName: "source-process")
        }
    }

    private struct Fixture {
        let def: ArtifactReference
        let netlist: ArtifactReference
        let library: ArtifactReference
        let rules: ArtifactReference
        let technology: ArtifactReference
        init() throws {
            func ref(_ character: Character) throws -> ArtifactReference {
                try .init(digest: .init(algorithm: .sha256, hexadecimalValue: String(repeating: String(character), count: 64)),
                    byteCount: 10, descriptor: .init(role: .input, kind: try ArtifactKind(rawValue: "source"), format: .raw))
            }
            def = try ref("a"); netlist = try ref("b"); library = try ref("c")
            rules = try ref("d"); technology = try ref("e")
        }
        func corner(_ id: PEXCornerID, _ rc: PEXOpenRCXSourceModel.RCCorner) -> PEXRoutedCornerSource {
            .init(cornerID: id, selection: .init(processName: "source-process", corner: rc,
                rulesArtifactID: rules.id, technologyLEFArtifactID: technology.id,
                routingLayerNames: ["li1", "met1", "met2", "met3", "met4", "met5"]), rules: rules, technologyLEF: technology)
        }
        func configuration(_ corners: [PEXRoutedCornerSource]) -> NativeRoutedPEXConfiguration {
            .init(algorithm: .unionSheetAreaBoundaryV1, sources: .init(expectedDEF: def, expectedSourceNetlist: netlist, routedTechnologyLEF: technology, standardCellLEFs: [library], corners: corners),
                maximumCellSpanDatabaseUnits: 1000, extractionLimits: .init(maximumInputRecords: 1000, maximumStringBytes: 10000, maximumSourceRecords: 1000,
                    maximumWorkVisits: 10000, maximumTrackEntries: 1000, maximumCoordinateValues: 1000,
                    maximumGraphNodes: 1000, maximumGraphElements: 1000, maximumQueryReceipts: 1000),
                compilationLimits: .init(maximumSourceBytes: 10000, maximumLineBytes: 1000, maximumLines: 1000,
                    maximumRecords: 1000, maximumRows: 1000, maximumWorkVisits: 10000),
                preparationLimits: .init(maximumSourceBytes: 10000, maximumTotalSourceBytes: 100000, maximumRecords: 1000, maximumStringBytes: 10000, maximumWorkVisits: 10000, maximumNetlistManagedStorageBytes: 64000000, maximumNetlistAllocationBytes: 128000000))
        }
    }
}
