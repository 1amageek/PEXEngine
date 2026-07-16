import Foundation

public struct PEXExtractorCorrelation: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let correlationID: String
    public let primaryBackendID: String
    public let oracleBackendID: String
    public let corpusDigest: String
    public let primaryReportDigest: String
    public let oracleReportDigest: String
    public let cases: [CaseComparison]

    public init(
        correlationID: String,
        primaryBackendID: String,
        oracleBackendID: String,
        corpusDigest: String,
        primaryReportDigest: String,
        oracleReportDigest: String,
        cases: [CaseComparison],
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.correlationID = correlationID
        self.primaryBackendID = primaryBackendID
        self.oracleBackendID = oracleBackendID
        self.corpusDigest = corpusDigest.lowercased()
        self.primaryReportDigest = primaryReportDigest.lowercased()
        self.oracleReportDigest = oracleReportDigest.lowercased()
        self.cases = cases.sorted { $0.caseID < $1.caseID }
    }

    public var isStructurallyValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && !correlationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !primaryBackendID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !oracleBackendID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && primaryBackendID != oracleBackendID
            && Self.isSHA256(corpusDigest)
            && Self.isSHA256(primaryReportDigest)
            && Self.isSHA256(oracleReportDigest)
            && primaryReportDigest != oracleReportDigest
            && !cases.isEmpty
            && cases.map(\.caseID) == cases.map(\.caseID).sorted()
            && Set(cases.map(\.caseID)).count == cases.count
            && cases.allSatisfy(\.isStructurallyValid)
    }

    public var passed: Bool {
        isStructurallyValid && cases.allSatisfy(\.passed)
    }

    public func canonicalData() throws -> Data {
        guard isStructurallyValid else {
            throw PEXEvidenceValidationError.correlationContentMismatch
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decodeCanonical(from data: Data) throws -> Self {
        let correlation = try JSONDecoder().decode(Self.self, from: data)
        guard correlation.isStructurallyValid,
              try correlation.canonicalData() == data else {
            throw PEXEvidenceValidationError.correlationContentMismatch
        }
        return correlation
    }

    public struct CaseComparison: Sendable, Hashable, Codable {
        public let caseID: String
        public let coverageTags: [String]
        public let metrics: [MetricComparison]

        public init(
            caseID: String,
            coverageTags: [String],
            metrics: [MetricComparison]
        ) {
            self.caseID = caseID
            self.coverageTags = Array(Set(coverageTags)).sorted()
            self.metrics = metrics.sorted { $0.metricID < $1.metricID }
        }

        public var isStructurallyValid: Bool {
            !caseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !coverageTags.isEmpty
                && coverageTags == Array(Set(coverageTags)).sorted()
                && !metrics.isEmpty
                && metrics.map(\.metricID) == metrics.map(\.metricID).sorted()
                && Set(metrics.map(\.metricID)).count == metrics.count
                && metrics.allSatisfy(\.isStructurallyValid)
        }

        public var passed: Bool {
            isStructurallyValid && metrics.allSatisfy(\.passed)
        }
    }

    public struct MetricComparison: Sendable, Hashable, Codable {
        public let metricID: String
        public let primaryObserved: Double
        public let oracleObserved: Double
        public let expected: Double
        public let absoluteTolerance: Double

        public init(
            metricID: String,
            primaryObserved: Double,
            oracleObserved: Double,
            expected: Double,
            absoluteTolerance: Double
        ) {
            self.metricID = metricID
            self.primaryObserved = primaryObserved
            self.oracleObserved = oracleObserved
            self.expected = expected
            self.absoluteTolerance = absoluteTolerance
        }

        public var isStructurallyValid: Bool {
            !metricID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && primaryObserved.isFinite
                && oracleObserved.isFinite
                && expected.isFinite
                && absoluteTolerance.isFinite
                && absoluteTolerance >= 0
        }

        public var passed: Bool {
            isStructurallyValid
                && abs(primaryObserved - expected) <= absoluteTolerance
                && abs(oracleObserved - expected) <= absoluteTolerance
                && abs(primaryObserved - oracleObserved) <= absoluteTolerance
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 70)
                || (byte >= 97 && byte <= 102)
        }
    }
}
