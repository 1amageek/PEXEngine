import Foundation

public struct PEXExtractorCorpus: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var corpusID: String
    public var cases: [Case]

    public init(
        corpusID: String,
        cases: [Case],
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.corpusID = corpusID
        self.cases = cases.sorted { $0.caseID < $1.caseID }
    }

    public var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && !corpusID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cases.isEmpty
            && Set(cases.map(\.caseID)).count == cases.count
            && cases.allSatisfy(\.isValid)
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decodeCanonical(from data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.isValid, try value.canonicalData() == data else {
            throw PEXEvidenceValidationError.corpusMismatch
        }
        return value
    }

    public struct Case: Sendable, Hashable, Codable {
        public var caseID: String
        public var topCell: String?
        public var corner: String?
        public var corners: [String]?
        public var coverageTags: [String]
        public var expectedGroundCapF: Double?
        public var expectedCouplingCapF: Double?
        public var expectedTotalCapacitanceF: Double?
        public var expectedResistanceOhm: Double?
        public var groundCapToleranceF: Double?
        public var couplingCapToleranceF: Double?
        public var totalCapacitanceToleranceF: Double?
        public var resistanceToleranceOhm: Double?

        public init(
            caseID: String,
            topCell: String? = nil,
            corner: String? = nil,
            corners: [String]? = nil,
            coverageTags: [String],
            expectedGroundCapF: Double? = nil,
            expectedCouplingCapF: Double? = nil,
            expectedTotalCapacitanceF: Double? = nil,
            expectedResistanceOhm: Double? = nil,
            groundCapToleranceF: Double? = nil,
            couplingCapToleranceF: Double? = nil,
            totalCapacitanceToleranceF: Double? = nil,
            resistanceToleranceOhm: Double? = nil
        ) {
            self.caseID = caseID
            self.topCell = topCell
            self.corner = corner
            self.corners = corners?.sorted()
            self.coverageTags = Array(Set(coverageTags)).sorted()
            self.expectedGroundCapF = expectedGroundCapF
            self.expectedCouplingCapF = expectedCouplingCapF
            self.expectedTotalCapacitanceF = expectedTotalCapacitanceF
            self.expectedResistanceOhm = expectedResistanceOhm
            self.groundCapToleranceF = groundCapToleranceF
            self.couplingCapToleranceF = couplingCapToleranceF
            self.totalCapacitanceToleranceF = totalCapacitanceToleranceF
            self.resistanceToleranceOhm = resistanceToleranceOhm
        }

        public var isValid: Bool {
            let expectations = [
                expectedGroundCapF,
                expectedCouplingCapF,
                expectedTotalCapacitanceF,
                expectedResistanceOhm,
            ].compactMap { $0 }
            return !caseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !coverageTags.isEmpty
                && coverageTags == Array(Set(coverageTags)).sorted()
                && topCell.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
                && corner.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
                && corners.map { !$0.isEmpty && $0 == Array(Set($0)).sorted() } ?? true
                && !expectations.isEmpty
                && expectations.allSatisfy(\.isFinite)
                && Self.isValidPair(expectedGroundCapF, groundCapToleranceF)
                && Self.isValidPair(expectedCouplingCapF, couplingCapToleranceF)
                && Self.isValidPair(expectedTotalCapacitanceF, totalCapacitanceToleranceF)
                && Self.isValidPair(expectedResistanceOhm, resistanceToleranceOhm)
        }

        private static func isValidPair(_ expected: Double?, _ tolerance: Double?) -> Bool {
            switch (expected, tolerance) {
            case let (.some(expected), .some(tolerance)):
                expected.isFinite && tolerance.isFinite && tolerance >= 0
            case (.none, .none):
                true
            default:
                false
            }
        }
    }
}
