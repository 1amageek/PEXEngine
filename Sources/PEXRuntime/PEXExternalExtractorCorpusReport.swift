import Foundation
import PEXCore

public struct PEXExternalExtractorCorpusReport: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let corpusSpec: String
    public let extractorBackendID: String
    public let status: String
    public let summary: Summary
    public let evaluation: Evaluation
    public let cases: [CaseResult]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        corpusSpec: String,
        extractorBackendID: String,
        status: String,
        summary: Summary,
        evaluation: Evaluation,
        cases: [CaseResult]
    ) {
        self.schemaVersion = schemaVersion
        self.corpusSpec = corpusSpec
        self.extractorBackendID = extractorBackendID
        self.status = status
        self.summary = summary
        self.evaluation = evaluation
        self.cases = cases
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decodeCanonical(from data: Data) throws -> Self {
        let report = try JSONDecoder().decode(Self.self, from: data)
        guard try report.canonicalData() == data else {
            throw PEXEvidenceValidationError.reportDecodeFailed("non-canonical")
        }
        return report
    }

    public struct Summary: Sendable, Hashable, Codable {
        public let caseCount: Int
        public let passedCaseCount: Int
        public let failedCaseCount: Int
        public let passRate: Double
        public let coverageTagCounts: [String: Int]
        public let totalGroundCapF: Double
        public let totalCouplingCapF: Double
        public let totalCapacitanceF: Double
        public let totalResistanceOhm: Double
        public let totalNetCount: Int
        public let totalElementCount: Int

        public init(
            caseCount: Int,
            passedCaseCount: Int,
            failedCaseCount: Int,
            passRate: Double,
            coverageTagCounts: [String: Int],
            totalGroundCapF: Double,
            totalCouplingCapF: Double,
            totalCapacitanceF: Double,
            totalResistanceOhm: Double,
            totalNetCount: Int,
            totalElementCount: Int
        ) {
            self.caseCount = caseCount
            self.passedCaseCount = passedCaseCount
            self.failedCaseCount = failedCaseCount
            self.passRate = passRate
            self.coverageTagCounts = coverageTagCounts
            self.totalGroundCapF = totalGroundCapF
            self.totalCouplingCapF = totalCouplingCapF
            self.totalCapacitanceF = totalCapacitanceF
            self.totalResistanceOhm = totalResistanceOhm
            self.totalNetCount = totalNetCount
            self.totalElementCount = totalElementCount
        }
    }

    public struct Evaluation: Sendable, Hashable, Codable {
        public let policy: Policy
        public let failures: [EvaluationFailure]

        public init(policy: Policy, failures: [EvaluationFailure]) {
            self.policy = policy
            self.failures = failures
        }

        public var passed: Bool { failures.isEmpty }
    }

    public struct Policy: Sendable, Hashable, Codable {
        public let requiredCoverageTags: [String]
        public let minimumPassRate: Double

        public init(requiredCoverageTags: [String], minimumPassRate: Double) {
            self.requiredCoverageTags = requiredCoverageTags
            self.minimumPassRate = minimumPassRate
        }
    }

    public struct EvaluationFailure: Sendable, Hashable, Codable {
        public let code: String
        public let caseID: String?
        public let failureCode: String?
        public let missingTags: [String]?

        public init(
            code: String,
            caseID: String? = nil,
            failureCode: String? = nil,
            missingTags: [String]? = nil
        ) {
            self.code = code
            self.caseID = caseID
            self.failureCode = failureCode
            self.missingTags = missingTags
        }
    }

    public struct CaseResult: Sendable, Hashable, Codable {
        public struct ArtifactRef: Sendable, Hashable, Codable {
            public let artifactID: String
            public let path: String
            public let role: String
            public let kind: String
            public let format: String
            public let sha256: String?
            public let byteCount: Int?
            public let sourceField: String?

            public init(
                artifactID: String,
                path: String,
                role: String,
                kind: String,
                format: String,
                sha256: String? = nil,
                byteCount: Int? = nil,
                sourceField: String? = nil
            ) {
                self.artifactID = artifactID
                self.path = path
                self.role = role
                self.kind = kind
                self.format = format
                self.sha256 = sha256
                self.byteCount = byteCount
                self.sourceField = sourceField
            }
        }

        public let caseID: String
        public let status: String
        public let topCell: String?
        public let corner: String?
        public let corners: [String]?
        public let layoutPath: String?
        public let sourceNetlistPath: String?
        public let technologyPath: String?
        public let technologyByCornerPaths: [String: String]?
        public let cornerDeckPaths: [String: String]?
        public let cornerDeckHashes: [String: String]?
        public let multiCorner: PEXExtractorMultiCornerSummary?
        public let outputDirectory: String?
        public let manifestPath: String?
        public let irPath: String?
        public let coverageTags: [String]
        public let totalGroundCapF: Double?
        public let totalCouplingCapF: Double?
        public let totalCapacitanceF: Double?
        public let totalResistanceOhm: Double?
        public let expectedGroundCapF: Double?
        public let expectedCouplingCapF: Double?
        public let expectedTotalCapacitanceF: Double?
        public let expectedResistanceOhm: Double?
        public let groundCapToleranceF: Double?
        public let couplingCapToleranceF: Double?
        public let totalCapacitanceToleranceF: Double?
        public let resistanceToleranceOhm: Double?
        public let toleranceF: Double?
        public let groundCapErrorF: Double?
        public let couplingCapErrorF: Double?
        public let totalCapacitanceErrorF: Double?
        public let resistanceErrorOhm: Double?
        public let netCount: Int?
        public let elementCount: Int?
        public let artifactRefs: [ArtifactRef]?
        public let failures: [CaseFailure]

        public init(
            caseID: String,
            status: String,
            topCell: String? = nil,
            corner: String? = nil,
            corners: [String]? = nil,
            layoutPath: String? = nil,
            sourceNetlistPath: String? = nil,
            technologyPath: String? = nil,
            technologyByCornerPaths: [String: String]? = nil,
            cornerDeckPaths: [String: String]? = nil,
            cornerDeckHashes: [String: String]? = nil,
            multiCorner: PEXExtractorMultiCornerSummary? = nil,
            outputDirectory: String? = nil,
            manifestPath: String? = nil,
            irPath: String? = nil,
            coverageTags: [String] = [],
            totalGroundCapF: Double? = nil,
            totalCouplingCapF: Double? = nil,
            totalCapacitanceF: Double? = nil,
            totalResistanceOhm: Double? = nil,
            expectedGroundCapF: Double? = nil,
            expectedCouplingCapF: Double? = nil,
            expectedTotalCapacitanceF: Double? = nil,
            expectedResistanceOhm: Double? = nil,
            groundCapToleranceF: Double? = nil,
            couplingCapToleranceF: Double? = nil,
            totalCapacitanceToleranceF: Double? = nil,
            resistanceToleranceOhm: Double? = nil,
            toleranceF: Double? = nil,
            groundCapErrorF: Double? = nil,
            couplingCapErrorF: Double? = nil,
            totalCapacitanceErrorF: Double? = nil,
            resistanceErrorOhm: Double? = nil,
            netCount: Int? = nil,
            elementCount: Int? = nil,
            artifactRefs: [ArtifactRef]? = nil,
            failures: [CaseFailure] = []
        ) {
            self.caseID = caseID
            self.status = status
            self.topCell = topCell
            self.corner = corner
            self.corners = corners
            self.layoutPath = layoutPath
            self.sourceNetlistPath = sourceNetlistPath
            self.technologyPath = technologyPath
            self.technologyByCornerPaths = technologyByCornerPaths
            self.cornerDeckPaths = cornerDeckPaths
            self.cornerDeckHashes = cornerDeckHashes
            self.multiCorner = multiCorner
            self.outputDirectory = outputDirectory
            self.manifestPath = manifestPath
            self.irPath = irPath
            self.coverageTags = Array(Set(coverageTags.filter { !$0.isEmpty })).sorted()
            self.totalGroundCapF = totalGroundCapF
            self.totalCouplingCapF = totalCouplingCapF
            self.totalCapacitanceF = totalCapacitanceF
            self.totalResistanceOhm = totalResistanceOhm
            self.expectedGroundCapF = expectedGroundCapF
            self.expectedCouplingCapF = expectedCouplingCapF
            self.expectedTotalCapacitanceF = expectedTotalCapacitanceF
            self.expectedResistanceOhm = expectedResistanceOhm
            self.groundCapToleranceF = groundCapToleranceF
            self.couplingCapToleranceF = couplingCapToleranceF
            self.totalCapacitanceToleranceF = totalCapacitanceToleranceF
            self.resistanceToleranceOhm = resistanceToleranceOhm
            self.toleranceF = toleranceF
            self.groundCapErrorF = groundCapErrorF
            self.couplingCapErrorF = couplingCapErrorF
            self.totalCapacitanceErrorF = totalCapacitanceErrorF
            self.resistanceErrorOhm = resistanceErrorOhm
            self.netCount = netCount
            self.elementCount = elementCount
            self.artifactRefs = artifactRefs?.sorted { $0.artifactID < $1.artifactID }
            self.failures = failures
        }
    }

    public struct CaseFailure: Sendable, Hashable, Codable {
        public let code: String
        public let corner: String?
        public let metric: String?
        public let expected: Double?
        public let observed: Double?
        public let tolerance: Double?
        public let message: String?
        public let status: String?
        public let expectedKey: String?
        public let toleranceKeys: [String]?

        public init(
            code: String,
            corner: String? = nil,
            metric: String? = nil,
            expected: Double? = nil,
            observed: Double? = nil,
            tolerance: Double? = nil,
            message: String? = nil,
            status: String? = nil,
            expectedKey: String? = nil,
            toleranceKeys: [String]? = nil
        ) {
            self.code = code
            self.corner = corner
            self.metric = metric
            self.expected = expected
            self.observed = observed
            self.tolerance = tolerance
            self.message = message
            self.status = status
            self.expectedKey = expectedKey
            self.toleranceKeys = toleranceKeys
        }
    }
}
