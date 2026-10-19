import Foundation
import CircuiteFoundation

/// Original source tables, not an analytical stack or an extraction qualification.
public struct PEXOpenRCXSourceModel: Sendable, Hashable, Codable {
    public enum Profile: String, Sendable, Hashable, Codable {
        case pinnedV1 = "openlane-calibre-v1-openroad-435b3fb7"
        public var version: Double { 1 }
        public var overCell: Bool { false }
        public var contextDepth: Int { 5 }
        public var diagonalContextDepth: Int { 3 }
        public var lateralContextTracks: Int { 10 }
        public var couplingThresholdFemtofarads: Double { 0 }
        public var mergeViaResistance: Bool { false }
        public var includesPinCapacitance: Bool { false }
        public var usesLEFWireResistance: Bool { true }
        public var consumerRevision: String { "435b3fb7a540d8206f99d894e0fab14251e95c7a" }
        public var flowRevision: String { "86f34b3484a1709e9058c6bfa4b1bc49aeae8335" }
        public var temperatureScaling: String { "source-unscaled" }
    }
    public enum RCCorner: String, Sendable, Hashable, Codable {
        case nominal = "nom", minimum = "min", maximum = "max"
    }
    public struct Selection: Sendable, Hashable, Codable {
        public let processName: String
        public let corner: RCCorner
        public let rulesArtifactID: ArtifactID
        public let technologyLEFArtifactID: ArtifactID
        public let routingLayerNames: [String]
        public init(processName: String, corner: RCCorner, rulesArtifactID: ArtifactID,
                    technologyLEFArtifactID: ArtifactID, routingLayerNames: [String]) {
            self.processName = processName; self.corner = corner
            self.rulesArtifactID = rulesArtifactID; self.technologyLEFArtifactID = technologyLEFArtifactID
            self.routingLayerNames = routingLayerNames
        }
        public func validate() throws(PEXOpenRCXSourceError) {
            guard !processName.isEmpty, routingLayerNames.count == 6,
                  routingLayerNames.allSatisfy({ !$0.isEmpty }), Set(routingLayerNames).count == 6,
                  rulesArtifactID.byteCount > 0, technologyLEFArtifactID.byteCount > 0,
                  rulesArtifactID.digest.algorithm == .sha256,
                  technologyLEFArtifactID.digest.algorithm == .sha256 else {
                throw .invalidSelection("Exact rules/technology identities and six injective routing names are required")
            }
        }
    }
    public struct SourceRange: Sendable, Hashable, Codable {
        public let lowerBound: Int
        public let upperBound: Int
        public init(lowerBound: Int, upperBound: Int) { self.lowerBound = lowerBound; self.upperBound = upperBound }
    }
    public enum Kind: String, Sendable, Hashable, Codable {
        case resOver = "RESOVER", over = "OVER", under = "UNDER", overUnder = "OVERUNDER", diagUnder = "DIAGUNDER"
    }
    public struct Context: Sendable, Hashable, Codable {
        public let metal: Int
        public let kind: Kind
        public let underMetal: Int?
        public let overMetal: Int?
        public init(metal: Int, kind: Kind, underMetal: Int? = nil, overMetal: Int? = nil) {
            self.metal = metal; self.kind = kind; self.underMetal = underMetal; self.overMetal = overMetal
        }
    }
    public struct Family: Sendable, Hashable, Codable {
        public let metal: Int
        public let kind: Kind
        public let widthsMicrons: [Double]
        public let sourceRange: SourceRange
        public init(metal: Int, kind: Kind, widthsMicrons: [Double], sourceRange: SourceRange) {
            self.metal = metal; self.kind = kind; self.widthsMicrons = widthsMicrons; self.sourceRange = sourceRange
        }
    }
    public struct CapacitanceSample: Sendable, Hashable, Codable {
        public let distanceMicrons: Double
        public let couplingFemtofaradsPerNanometer: Double
        public let fringeFemtofaradsPerNanometer: Double
        /// Retained source column; the selected profile takes wire resistance from LEF.
        public let resistanceOhmsPerNanometer: Double
        public let sourceRange: SourceRange
        public init(distanceMicrons: Double, couplingFemtofaradsPerNanometer: Double,
                    fringeFemtofaradsPerNanometer: Double, resistanceOhmsPerNanometer: Double, sourceRange: SourceRange) {
            self.distanceMicrons = distanceMicrons; self.couplingFemtofaradsPerNanometer = couplingFemtofaradsPerNanometer
            self.fringeFemtofaradsPerNanometer = fringeFemtofaradsPerNanometer
            self.resistanceOhmsPerNanometer = resistanceOhmsPerNanometer; self.sourceRange = sourceRange
        }
    }
    public struct ResistanceSample: Sendable, Hashable, Codable {
        public let firstSpacingMicrons: Double
        public let secondSpacingMicrons: Double
        public let fringeFemtofaradsPerNanometer: Double
        public let resistanceOhmsPerNanometer: Double
        public let sourceRange: SourceRange
        public init(firstSpacingMicrons: Double, secondSpacingMicrons: Double,
                    fringeFemtofaradsPerNanometer: Double, resistanceOhmsPerNanometer: Double, sourceRange: SourceRange) {
            self.firstSpacingMicrons = firstSpacingMicrons; self.secondSpacingMicrons = secondSpacingMicrons
            self.fringeFemtofaradsPerNanometer = fringeFemtofaradsPerNanometer
            self.resistanceOhmsPerNanometer = resistanceOhmsPerNanometer; self.sourceRange = sourceRange
        }
    }
    public struct Table: Sendable, Hashable, Codable {
        public let context: Context
        public let widthMicrons: Double
        public let sourceRange: SourceRange
        public let capacitanceSamples: [CapacitanceSample]
        public let resistanceSamples: [ResistanceSample]
        public init(context: Context, widthMicrons: Double, sourceRange: SourceRange,
                    capacitanceSamples: [CapacitanceSample] = [], resistanceSamples: [ResistanceSample] = []) {
            self.context = context; self.widthMicrons = widthMicrons; self.sourceRange = sourceRange
            self.capacitanceSamples = capacitanceSamples; self.resistanceSamples = resistanceSamples
        }
        public var isEmpty: Bool { capacitanceSamples.isEmpty && resistanceSamples.isEmpty }
    }

    public let selection: Selection
    public let profile: Profile
    public let sourceHeaderRange: SourceRange
    public let families: [Family]
    public let tables: [Table]

    public init(selection: Selection, profile: Profile = .pinnedV1, sourceHeaderRange: SourceRange,
                families: [Family], tables: [Table]) throws(PEXOpenRCXSourceError) {
        self.selection = selection; self.profile = profile; self.sourceHeaderRange = sourceHeaderRange
        self.families = families; self.tables = tables
        try validate()
    }

    /// Structural admission only; source authenticity additionally requires compiler replay.
    public func validate() throws(PEXOpenRCXSourceError) {
        try selection.validate()
        guard let byteCount = Int(exactly: selection.rulesArtifactID.byteCount),
              families.count == 28, tables.count == 92 else { throw .invalidModel("Source inventory") }
        func contains(_ range: SourceRange, in outer: SourceRange) -> Bool {
            range.lowerBound >= outer.lowerBound && range.upperBound > range.lowerBound && range.upperBound <= outer.upperBound
        }
        let source = SourceRange(lowerBound: 0, upperBound: byteCount)
        guard contains(sourceHeaderRange, in: source), sourceHeaderRange.lowerBound == 0 else {
            throw .invalidModel("Source header range")
        }
        struct FamilyKey: Hashable { let metal: Int; let kind: Kind }
        var inventory: [FamilyKey: Family] = [:]
        var previousEnd = sourceHeaderRange.upperBound
        for family in families {
            guard (1...6).contains(family.metal), contains(family.sourceRange, in: source),
                  family.sourceRange.lowerBound >= previousEnd,
                  family.widthsMicrons.count == (family.metal == 6 && (family.kind == .under || family.kind == .diagUnder) ? 0 : 1),
                  family.widthsMicrons.allSatisfy({ $0.isFinite && $0 > 0 }),
                  family.kind != .overUnder || (2...5).contains(family.metal),
                  inventory.updateValue(family, forKey: FamilyKey(metal: family.metal, kind: family.kind)) == nil else {
                throw .invalidModel("Family identity, widths or source range")
            }
            previousEnd = family.sourceRange.upperBound
        }
        var expected = Set<Context>()
        for metal in 1...6 {
            for kind in [Kind.resOver, .over, .under, .diagUnder] {
                guard inventory[FamilyKey(metal: metal, kind: kind)] != nil else { throw .invalidModel("Missing family") }
            }
            for lower in 0..<metal {
                expected.insert(Context(metal: metal, kind: .resOver, underMetal: lower))
                expected.insert(Context(metal: metal, kind: .over, underMetal: lower))
            }
            if metal < 6 {
                for upper in (metal + 1)...6 {
                    expected.insert(Context(metal: metal, kind: .under, overMetal: upper))
                    expected.insert(Context(metal: metal, kind: .diagUnder, overMetal: upper))
                }
            }
            if (2...5).contains(metal) {
                guard inventory[FamilyKey(metal: metal, kind: .overUnder)] != nil else { throw .invalidModel("Missing OVERUNDER family") }
                for lower in 1..<metal { for upper in (metal + 1)...6 {
                    expected.insert(Context(metal: metal, kind: .overUnder, underMetal: lower, overMetal: upper))
                } }
            }
        }
        var tableEnds: [FamilyKey: Int] = [:]
        for table in tables {
            let key = FamilyKey(metal: table.context.metal, kind: table.context.kind)
            guard expected.remove(table.context) != nil, let family = inventory[key],
                  family.widthsMicrons == [table.widthMicrons], contains(table.sourceRange, in: family.sourceRange),
                  table.sourceRange.lowerBound >= (tableEnds[key] ?? family.sourceRange.lowerBound) else {
                throw .invalidModel("Table context, width or source range")
            }
            tableEnds[key] = table.sourceRange.upperBound
            var rowEnd = table.sourceRange.lowerBound
            func rowRange(_ range: SourceRange) -> Bool {
                guard contains(range, in: table.sourceRange), range.lowerBound >= rowEnd else { return false }
                rowEnd = range.upperBound
                return true
            }
            if table.context.kind == .resOver {
                guard table.capacitanceSamples.isEmpty else { throw .invalidModel("RESOVER row type") }
                var previous: ResistanceSample?
                for row in table.resistanceSamples {
                    guard [row.firstSpacingMicrons, row.secondSpacingMicrons, row.fringeFemtofaradsPerNanometer,
                           row.resistanceOhmsPerNanometer].allSatisfy({ $0.isFinite && $0 >= 0 }), rowRange(row.sourceRange) else {
                        throw .invalidModel("Resistance row")
                    }
                    if let previous {
                        guard row.firstSpacingMicrons > previous.firstSpacingMicrons
                                || (row.firstSpacingMicrons == previous.firstSpacingMicrons && row.secondSpacingMicrons > previous.secondSpacingMicrons) else {
                            throw .invalidModel("Resistance spacing order")
                        }
                    }
                    previous = row
                }
            } else {
                guard table.resistanceSamples.isEmpty else { throw .invalidModel("Capacitance row type") }
                var previous = -Double.infinity
                for row in table.capacitanceSamples {
                    guard [row.distanceMicrons, row.couplingFemtofaradsPerNanometer, row.fringeFemtofaradsPerNanometer,
                           row.resistanceOhmsPerNanometer].allSatisfy({ $0.isFinite && $0 >= 0 }),
                          row.distanceMicrons > previous, rowRange(row.sourceRange) else { throw .invalidModel("Capacitance row") }
                    previous = row.distanceMicrons
                }
            }
        }
        guard expected.isEmpty else { throw .invalidModel("Missing table context") }
    }

    public func domainDigest() throws -> ContentDigest {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try ContentDigest(algorithm: .sha256, hexadecimalValue: PEXRequestHash.compute(from: encoder.encode(self)).value)
    }

    private enum CodingKeys: String, CodingKey { case selection, profile, sourceHeaderRange, families, tables }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(selection: values.decode(Selection.self, forKey: .selection),
                      profile: values.decode(Profile.self, forKey: .profile),
                      sourceHeaderRange: values.decode(SourceRange.self, forKey: .sourceHeaderRange),
                      families: values.decode([Family].self, forKey: .families),
                      tables: values.decode([Table].self, forKey: .tables))
    }
}
