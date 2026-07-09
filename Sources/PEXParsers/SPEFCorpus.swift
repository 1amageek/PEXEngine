import Foundation

public enum SPEFCorpus {
    public struct Manifest: Sendable, Hashable, Codable {
        public let schemaVersion: Int
        public let sourceRepository: String
        public let pinnedCommit: String
        public let sourceDirectory: String
        public let license: String
        public let qualificationPolicy: QualificationPolicy
        public let fixtures: [Fixture]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case sourceRepository
            case pinnedCommit
            case sourceDirectory
            case license
            case qualificationPolicy
            case fixtures
        }

        public init(
            schemaVersion: Int,
            sourceRepository: String,
            pinnedCommit: String,
            sourceDirectory: String,
            license: String,
            qualificationPolicy: QualificationPolicy = .strict,
            fixtures: [Fixture]
        ) {
            self.schemaVersion = schemaVersion
            self.sourceRepository = sourceRepository
            self.pinnedCommit = pinnedCommit
            self.sourceDirectory = sourceDirectory
            self.license = license
            self.qualificationPolicy = qualificationPolicy
            self.fixtures = fixtures
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            sourceRepository = try container.decode(String.self, forKey: .sourceRepository)
            pinnedCommit = try container.decode(String.self, forKey: .pinnedCommit)
            sourceDirectory = try container.decode(String.self, forKey: .sourceDirectory)
            license = try container.decode(String.self, forKey: .license)
            qualificationPolicy = try container.decodeIfPresent(
                QualificationPolicy.self,
                forKey: .qualificationPolicy
            ) ?? .strict
            fixtures = try container.decode([Fixture].self, forKey: .fixtures)
        }
    }

    public struct Fixture: Sendable, Hashable, Codable {
        public let fileName: String
        public let sourcePath: String
        public let gitBlobSHA: String
        public let sha256: String
        public let byteCount: Int
        public let designName: String
        public let coverageTags: [String]
        public let parseSummary: ParseSummary
        public let loweredSummary: LoweredSummary

        private enum CodingKeys: String, CodingKey {
            case fileName
            case sourcePath
            case gitBlobSHA
            case sha256
            case byteCount
            case designName
            case coverageTags
            case parseSummary
            case loweredSummary
        }

        public init(
            fileName: String,
            sourcePath: String,
            gitBlobSHA: String,
            sha256: String,
            byteCount: Int,
            designName: String,
            coverageTags: [String] = [],
            parseSummary: ParseSummary,
            loweredSummary: LoweredSummary
        ) {
            self.fileName = fileName
            self.sourcePath = sourcePath
            self.gitBlobSHA = gitBlobSHA
            self.sha256 = sha256
            self.byteCount = byteCount
            self.designName = designName
            self.coverageTags = Self.normalizedCoverageTags(coverageTags)
            self.parseSummary = parseSummary
            self.loweredSummary = loweredSummary
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fileName = try container.decode(String.self, forKey: .fileName)
            sourcePath = try container.decode(String.self, forKey: .sourcePath)
            gitBlobSHA = try container.decode(String.self, forKey: .gitBlobSHA)
            sha256 = try container.decode(String.self, forKey: .sha256)
            byteCount = try container.decode(Int.self, forKey: .byteCount)
            designName = try container.decode(String.self, forKey: .designName)
            coverageTags = Self.normalizedCoverageTags(try container.decodeIfPresent(
                [String].self,
                forKey: .coverageTags
            ) ?? [])
            parseSummary = try container.decode(ParseSummary.self, forKey: .parseSummary)
            loweredSummary = try container.decode(LoweredSummary.self, forKey: .loweredSummary)
        }

        private static func normalizedCoverageTags(_ tags: [String]) -> [String] {
            Array(Set(tags.filter { !$0.isEmpty })).sorted()
        }
    }

    public struct ParseSummary: Sendable, Hashable, Codable {
        public let nameMapCount: Int
        public let portCount: Int
        public let netCount: Int
        public let connectionCount: Int
        public let capacitorCount: Int
        public let resistorCount: Int
        public let inductorCount: Int

        private enum CodingKeys: String, CodingKey {
            case nameMapCount
            case portCount
            case netCount
            case connectionCount
            case capacitorCount
            case resistorCount
            case inductorCount
        }

        public init(
            nameMapCount: Int,
            portCount: Int,
            netCount: Int,
            connectionCount: Int,
            capacitorCount: Int,
            resistorCount: Int,
            inductorCount: Int = 0
        ) {
            self.nameMapCount = nameMapCount
            self.portCount = portCount
            self.netCount = netCount
            self.connectionCount = connectionCount
            self.capacitorCount = capacitorCount
            self.resistorCount = resistorCount
            self.inductorCount = inductorCount
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nameMapCount = try container.decode(Int.self, forKey: .nameMapCount)
            portCount = try container.decode(Int.self, forKey: .portCount)
            netCount = try container.decode(Int.self, forKey: .netCount)
            connectionCount = try container.decode(Int.self, forKey: .connectionCount)
            capacitorCount = try container.decode(Int.self, forKey: .capacitorCount)
            resistorCount = try container.decode(Int.self, forKey: .resistorCount)
            inductorCount = try container.decodeIfPresent(Int.self, forKey: .inductorCount) ?? 0
        }

        public init(tree: SPEFParseTree) {
            self.init(
                nameMapCount: tree.nameMap.count,
                portCount: tree.ports.count,
                netCount: tree.nets.count,
                connectionCount: tree.nets.reduce(0) { $0 + $1.connections.count },
                capacitorCount: tree.nets.reduce(0) { $0 + $1.capacitors.count },
                resistorCount: tree.nets.reduce(0) { $0 + $1.resistors.count },
                inductorCount: tree.nets.reduce(0) { $0 + $1.inductors.count }
            )
        }
    }

    public struct LoweredSummary: Sendable, Hashable, Codable {
        public let netCount: Int
        public let elementCount: Int
        public let capacitorElementCount: Int
        public let couplingElementCount: Int
        public let resistorElementCount: Int
        public let inductorElementCount: Int
        public let totalGroundCapF: Double
        public let totalCouplingCapF: Double
        public let totalResistanceOhm: Double
        public let totalInductanceH: Double
        public let capTolerance: Double
        public let resistanceTolerance: Double
        public let inductanceTolerance: Double

        private enum CodingKeys: String, CodingKey {
            case netCount
            case elementCount
            case capacitorElementCount
            case couplingElementCount
            case resistorElementCount
            case inductorElementCount
            case totalGroundCapF
            case totalCouplingCapF
            case totalResistanceOhm
            case totalInductanceH
            case capTolerance
            case resistanceTolerance
            case inductanceTolerance
        }

        public init(
            netCount: Int,
            elementCount: Int,
            capacitorElementCount: Int,
            couplingElementCount: Int,
            resistorElementCount: Int,
            inductorElementCount: Int = 0,
            totalGroundCapF: Double,
            totalCouplingCapF: Double,
            totalResistanceOhm: Double,
            totalInductanceH: Double = 0,
            capTolerance: Double,
            resistanceTolerance: Double = 1e-9,
            inductanceTolerance: Double = 1e-18
        ) {
            self.netCount = netCount
            self.elementCount = elementCount
            self.capacitorElementCount = capacitorElementCount
            self.couplingElementCount = couplingElementCount
            self.resistorElementCount = resistorElementCount
            self.inductorElementCount = inductorElementCount
            self.totalGroundCapF = totalGroundCapF
            self.totalCouplingCapF = totalCouplingCapF
            self.totalResistanceOhm = totalResistanceOhm
            self.totalInductanceH = totalInductanceH
            self.capTolerance = capTolerance
            self.resistanceTolerance = resistanceTolerance
            self.inductanceTolerance = inductanceTolerance
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            netCount = try container.decode(Int.self, forKey: .netCount)
            elementCount = try container.decode(Int.self, forKey: .elementCount)
            capacitorElementCount = try container.decode(Int.self, forKey: .capacitorElementCount)
            couplingElementCount = try container.decode(Int.self, forKey: .couplingElementCount)
            resistorElementCount = try container.decode(Int.self, forKey: .resistorElementCount)
            inductorElementCount = try container.decodeIfPresent(Int.self, forKey: .inductorElementCount) ?? 0
            totalGroundCapF = try container.decode(Double.self, forKey: .totalGroundCapF)
            totalCouplingCapF = try container.decode(Double.self, forKey: .totalCouplingCapF)
            totalResistanceOhm = try container.decode(Double.self, forKey: .totalResistanceOhm)
            totalInductanceH = try container.decodeIfPresent(Double.self, forKey: .totalInductanceH) ?? 0
            capTolerance = try container.decode(Double.self, forKey: .capTolerance)
            resistanceTolerance = try container.decodeIfPresent(
                Double.self,
                forKey: .resistanceTolerance
            ) ?? 1e-9
            inductanceTolerance = try container.decodeIfPresent(
                Double.self,
                forKey: .inductanceTolerance
            ) ?? 1e-18
        }
    }

    public struct CaseFailure: Sendable, Hashable, Codable {
        public let code: String
        public let category: String?
        public let message: String
        public let observedText: String?
        public let expectedText: String?
        public let observedDouble: Double?
        public let expectedDouble: Double?
        public let tolerance: Double?
        public let suggestedActions: [String]

        private enum CodingKeys: String, CodingKey {
            case code
            case category
            case message
            case observedText
            case expectedText
            case observedDouble
            case expectedDouble
            case tolerance
            case suggestedActions
        }

        public init(
            code: String,
            category: String? = nil,
            message: String,
            observedText: String? = nil,
            expectedText: String? = nil,
            observedDouble: Double? = nil,
            expectedDouble: Double? = nil,
            tolerance: Double? = nil,
            suggestedActions: [String] = []
        ) {
            self.code = code
            self.category = category
            self.message = message
            self.observedText = observedText
            self.expectedText = expectedText
            self.observedDouble = observedDouble
            self.expectedDouble = expectedDouble
            self.tolerance = tolerance
            self.suggestedActions = suggestedActions
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try container.decode(String.self, forKey: .code)
            category = try container.decodeIfPresent(String.self, forKey: .category)
            message = try container.decode(String.self, forKey: .message)
            observedText = try container.decodeIfPresent(String.self, forKey: .observedText)
            expectedText = try container.decodeIfPresent(String.self, forKey: .expectedText)
            observedDouble = try container.decodeIfPresent(Double.self, forKey: .observedDouble)
            expectedDouble = try container.decodeIfPresent(Double.self, forKey: .expectedDouble)
            tolerance = try container.decodeIfPresent(Double.self, forKey: .tolerance)
            suggestedActions = try container.decodeIfPresent([String].self, forKey: .suggestedActions) ?? []
        }
    }

    public struct CaseResult: Sendable, Hashable, Codable {
        public let fileName: String
        public let designName: String
        public let passed: Bool
        public let coverageTags: [String]
        public let observedParseSummary: ParseSummary?
        public let observedLoweredSummary: LoweredSummary?
        public let validationErrorCount: Int
        public let validationWarningCount: Int
        public let failures: [CaseFailure]

        public init(
            fileName: String,
            designName: String,
            passed: Bool,
            coverageTags: [String],
            observedParseSummary: ParseSummary? = nil,
            observedLoweredSummary: LoweredSummary? = nil,
            validationErrorCount: Int = 0,
            validationWarningCount: Int = 0,
            failures: [CaseFailure] = []
        ) {
            self.fileName = fileName
            self.designName = designName
            self.passed = passed
            self.coverageTags = Array(Set(coverageTags.filter { !$0.isEmpty })).sorted()
            self.observedParseSummary = observedParseSummary
            self.observedLoweredSummary = observedLoweredSummary
            self.validationErrorCount = validationErrorCount
            self.validationWarningCount = validationWarningCount
            self.failures = failures
        }
    }

    public struct Summary: Sendable, Hashable, Codable {
        public let caseCount: Int
        public let passedCaseCount: Int
        public let failedCaseCount: Int
        public let passRate: Double
        public let coverageTagCounts: [String: Int]
        public let totalNetCount: Int
        public let totalElementCount: Int
        public let totalGroundCapF: Double
        public let totalCouplingCapF: Double
        public let totalResistanceOhm: Double
        public let failureCodeCounts: [String: Int]
        public let failureCategoryCounts: [String: Int]

        private enum CodingKeys: String, CodingKey {
            case caseCount
            case passedCaseCount
            case failedCaseCount
            case passRate
            case coverageTagCounts
            case totalNetCount
            case totalElementCount
            case totalGroundCapF
            case totalCouplingCapF
            case totalResistanceOhm
            case failureCodeCounts
            case failureCategoryCounts
        }

        public init(caseResults: [CaseResult]) {
            let caseCount = caseResults.count
            let passedCaseCount = caseResults.filter(\.passed).count
            self.caseCount = caseCount
            self.passedCaseCount = passedCaseCount
            self.failedCaseCount = caseCount - passedCaseCount
            self.passRate = caseCount == 0 ? 1 : Double(passedCaseCount) / Double(caseCount)
            self.coverageTagCounts = Self.coverageTagCounts(in: caseResults)
            self.totalNetCount = caseResults.compactMap(\.observedLoweredSummary).reduce(0) { $0 + $1.netCount }
            self.totalElementCount = caseResults.compactMap(\.observedLoweredSummary).reduce(0) { $0 + $1.elementCount }
            self.totalGroundCapF = caseResults.compactMap(\.observedLoweredSummary).reduce(0) { $0 + $1.totalGroundCapF }
            self.totalCouplingCapF = caseResults.compactMap(\.observedLoweredSummary).reduce(0) { $0 + $1.totalCouplingCapF }
            self.totalResistanceOhm = caseResults.compactMap(\.observedLoweredSummary).reduce(0) { $0 + $1.totalResistanceOhm }
            self.failureCodeCounts = Self.failureCodeCounts(in: caseResults)
            self.failureCategoryCounts = Self.failureCategoryCounts(in: caseResults)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            caseCount = try container.decode(Int.self, forKey: .caseCount)
            passedCaseCount = try container.decode(Int.self, forKey: .passedCaseCount)
            failedCaseCount = try container.decode(Int.self, forKey: .failedCaseCount)
            passRate = try container.decode(Double.self, forKey: .passRate)
            coverageTagCounts = try container.decode([String: Int].self, forKey: .coverageTagCounts)
            totalNetCount = try container.decode(Int.self, forKey: .totalNetCount)
            totalElementCount = try container.decode(Int.self, forKey: .totalElementCount)
            totalGroundCapF = try container.decode(Double.self, forKey: .totalGroundCapF)
            totalCouplingCapF = try container.decode(Double.self, forKey: .totalCouplingCapF)
            totalResistanceOhm = try container.decode(Double.self, forKey: .totalResistanceOhm)
            failureCodeCounts = try container.decodeIfPresent(
                [String: Int].self,
                forKey: .failureCodeCounts
            ) ?? [:]
            failureCategoryCounts = try container.decodeIfPresent(
                [String: Int].self,
                forKey: .failureCategoryCounts
            ) ?? [:]
        }

        private static func coverageTagCounts(in caseResults: [CaseResult]) -> [String: Int] {
            var counts: [String: Int] = [:]
            for tag in caseResults.flatMap(\.coverageTags) {
                counts[tag, default: 0] += 1
            }
            return counts
        }

        private static func failureCodeCounts(in caseResults: [CaseResult]) -> [String: Int] {
            var counts: [String: Int] = [:]
            for code in caseResults.flatMap(\.failures).map(\.code) where !code.isEmpty {
                counts[code, default: 0] += 1
            }
            return counts
        }

        private static func failureCategoryCounts(in caseResults: [CaseResult]) -> [String: Int] {
            var counts: [String: Int] = [:]
            for category in caseResults.flatMap(\.failures).compactMap(\.category) where !category.isEmpty {
                counts[category, default: 0] += 1
            }
            return counts
        }
    }

    public struct QualificationFailure: Sendable, Hashable, Codable {
        public let code: String
        public let message: String
        public let observedDouble: Double?
        public let requiredDouble: Double?
        public let observedCount: Int?
        public let requiredCount: Int?
        public let observedText: String?
        public let requiredText: String?

        public init(
            code: String,
            message: String,
            observedDouble: Double? = nil,
            requiredDouble: Double? = nil,
            observedCount: Int? = nil,
            requiredCount: Int? = nil,
            observedText: String? = nil,
            requiredText: String? = nil
        ) {
            self.code = code
            self.message = message
            self.observedDouble = observedDouble
            self.requiredDouble = requiredDouble
            self.observedCount = observedCount
            self.requiredCount = requiredCount
            self.observedText = observedText
            self.requiredText = requiredText
        }
    }

    public struct QualificationPolicy: Sendable, Hashable, Codable {
        public static let strict = QualificationPolicy()

        public let requireCorpusPassed: Bool
        public let minimumPassRate: Double
        public let requiredCoverageTags: [String]

        private enum CodingKeys: String, CodingKey {
            case requireCorpusPassed
            case minimumPassRate
            case requiredCoverageTags
        }

        public init(
            requireCorpusPassed: Bool = true,
            minimumPassRate: Double = 1,
            requiredCoverageTags: [String] = []
        ) {
            self.requireCorpusPassed = requireCorpusPassed
            self.minimumPassRate = minimumPassRate
            self.requiredCoverageTags = Self.normalizedCoverageTags(requiredCoverageTags)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            requireCorpusPassed = try container.decodeIfPresent(Bool.self, forKey: .requireCorpusPassed) ?? true
            minimumPassRate = try container.decodeIfPresent(Double.self, forKey: .minimumPassRate) ?? 1
            requiredCoverageTags = Self.normalizedCoverageTags(try container.decodeIfPresent(
                [String].self,
                forKey: .requiredCoverageTags
            ) ?? [])
        }

        public func evaluate(summary: Summary) -> QualificationResult {
            var failures = validationFailures()
            if summary.caseCount == 0 {
                failures.append(QualificationFailure(
                    code: "corpus_empty",
                    message: "The SPEF corpus contains no fixture cases.",
                    observedCount: 0,
                    requiredCount: 1
                ))
            }
            if requireCorpusPassed && summary.failedCaseCount > 0 {
                failures.append(QualificationFailure(
                    code: "corpus_not_passed",
                    message: "The SPEF corpus did not pass every case.",
                    observedCount: summary.passedCaseCount,
                    requiredCount: summary.caseCount
                ))
            }
            if summary.passRate < minimumPassRate {
                failures.append(QualificationFailure(
                    code: "pass_rate_below_minimum",
                    message: "The SPEF corpus pass rate is below the required threshold.",
                    observedDouble: summary.passRate,
                    requiredDouble: minimumPassRate
                ))
            }
            let missingCoverageTags = requiredCoverageTags.filter { summary.coverageTagCounts[$0] == nil }
            if !missingCoverageTags.isEmpty {
                failures.append(QualificationFailure(
                    code: "required_coverage_missing",
                    message: "The SPEF corpus is missing one or more required coverage tags.",
                    observedCount: requiredCoverageTags.count - missingCoverageTags.count,
                    requiredCount: requiredCoverageTags.count,
                    observedText: summary.coverageTagCounts.keys.sorted().joined(separator: ","),
                    requiredText: missingCoverageTags.joined(separator: ",")
                ))
            }
            return QualificationResult(policy: self, failures: failures)
        }

        private func validationFailures() -> [QualificationFailure] {
            if minimumPassRate < 0 || minimumPassRate > 1 || !minimumPassRate.isFinite {
                return [
                    QualificationFailure(
                        code: "invalid_minimum_pass_rate",
                        message: "minimumPassRate must be a finite value between 0 and 1.",
                        observedDouble: minimumPassRate
                    )
                ]
            }
            return []
        }

        private static func normalizedCoverageTags(_ tags: [String]) -> [String] {
            Array(Set(tags.filter { !$0.isEmpty })).sorted()
        }
    }

    public struct QualificationResult: Sendable, Hashable, Codable {
        public let policy: QualificationPolicy
        public let failures: [QualificationFailure]
        public let qualified: Bool

        private enum CodingKeys: String, CodingKey {
            case policy
            case failures
            case qualified
        }

        public init(policy: QualificationPolicy, failures: [QualificationFailure]) {
            self.policy = policy
            self.failures = failures
            self.qualified = failures.isEmpty
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            policy = try container.decode(QualificationPolicy.self, forKey: .policy)
            failures = try container.decode([QualificationFailure].self, forKey: .failures)
            qualified = try container.decodeIfPresent(Bool.self, forKey: .qualified) ?? failures.isEmpty
        }
    }

    public struct FileReference: Sendable, Hashable, Codable {
        public let path: String
        public let kind: String
        public let format: String
        public let sha256: String?
        public let byteCount: Int?

        private enum CodingKeys: String, CodingKey {
            case path
            case kind
            case format
            case sha256
            case byteCount
        }

        public init(path: String, kind: String, format: String, sha256: String? = nil, byteCount: Int? = nil) {
            self.path = path
            self.kind = kind
            self.format = format
            self.sha256 = sha256
            self.byteCount = byteCount
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            kind = try container.decode(String.self, forKey: .kind)
            format = try container.decode(String.self, forKey: .format)
            sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
            byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount)
        }
    }

    public struct QualificationSummary: Sendable, Hashable, Codable {
        public let qualified: Bool
        public let policyID: String?
        public let observedMetrics: [String: Double]
        public let observedCounts: [String: Int]
        public let failureCodes: [String]

        public init(
            qualified: Bool,
            policyID: String?,
            observedMetrics: [String: Double],
            observedCounts: [String: Int],
            failureCodes: [String]
        ) {
            self.qualified = qualified
            self.policyID = policyID
            self.observedMetrics = observedMetrics
            self.observedCounts = observedCounts
            self.failureCodes = failureCodes
        }
    }

    public struct ToolEvidence: Sendable, Hashable, Codable {
        public let evidenceID: String
        public let kind: String
        public let artifact: FileReference
        public let qualification: QualificationSummary
        public let checkedAt: String?

        public init(
            evidenceID: String,
            kind: String = "corpus",
            artifact: FileReference,
            qualification: QualificationSummary,
            checkedAt: String? = nil
        ) {
            self.evidenceID = evidenceID
            self.kind = kind
            self.artifact = artifact
            self.qualification = qualification
            self.checkedAt = checkedAt
        }
    }

    public struct Report: Sendable, Hashable, Codable {
        public let schemaVersion: Int
        public let status: String
        public let manifestPath: String
        public let sourceRepository: String
        public let pinnedCommit: String
        public let sourceArtifacts: [FileReference]
        public let summary: Summary
        public let qualification: QualificationResult
        public let toolEvidence: ToolEvidence
        public let caseResults: [CaseResult]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case status
            case manifestPath
            case sourceRepository
            case pinnedCommit
            case sourceArtifacts
            case summary
            case qualification
            case toolEvidence
            case caseResults
        }

        public init(
            schemaVersion: Int = 1,
            manifestPath: String,
            manifest: Manifest,
            summary: Summary,
            qualification: QualificationResult,
            caseResults: [CaseResult]
        ) {
            self.schemaVersion = schemaVersion
            self.status = qualification.qualified ? "passed" : "failed"
            self.manifestPath = manifestPath
            self.sourceRepository = manifest.sourceRepository
            self.pinnedCommit = manifest.pinnedCommit
            self.sourceArtifacts = Self.sourceArtifacts(manifestPath: manifestPath, manifest: manifest)
            self.summary = summary
            self.qualification = qualification
            self.caseResults = caseResults
            let failureOccurrenceCount = summary.failureCodeCounts.values.reduce(0, +)
            self.toolEvidence = ToolEvidence(
                evidenceID: "pex-spef-corpus:\(URL(filePath: manifestPath).deletingPathExtension().lastPathComponent)",
                artifact: FileReference(
                    path: manifestPath,
                    kind: "corpus-manifest",
                    format: "JSON"
                ),
                qualification: QualificationSummary(
                    qualified: qualification.qualified,
                    policyID: qualification.policy == .strict ? "strict" : "custom",
                    observedMetrics: [
                        "passRate": summary.passRate,
                        "totalGroundCapF": summary.totalGroundCapF,
                        "totalCouplingCapF": summary.totalCouplingCapF,
                        "totalResistanceOhm": summary.totalResistanceOhm,
                    ],
                    observedCounts: [
                        "caseCount": summary.caseCount,
                        "passedCaseCount": summary.passedCaseCount,
                        "failedCaseCount": summary.failedCaseCount,
                        "coverageTagCount": summary.coverageTagCounts.count,
                        "failureOccurrenceCount": failureOccurrenceCount,
                        "failureCodeCount": summary.failureCodeCounts.count,
                        "failureCodeKindCount": summary.failureCodeCounts.count,
                        "failureCategoryCount": summary.failureCategoryCounts.count,
                        "failureCategoryKindCount": summary.failureCategoryCounts.count,
                        "requiredCoverageTagCount": qualification.policy.requiredCoverageTags.count,
                        "coveredRequiredCoverageTagCount": qualification.policy.requiredCoverageTags.filter {
                            summary.coverageTagCounts[$0] != nil
                        }.count,
                        "totalNetCount": summary.totalNetCount,
                        "totalElementCount": summary.totalElementCount,
                    ],
                    failureCodes: qualification.failures.map(\.code)
                )
            )
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            status = try container.decode(String.self, forKey: .status)
            manifestPath = try container.decode(String.self, forKey: .manifestPath)
            sourceRepository = try container.decode(String.self, forKey: .sourceRepository)
            pinnedCommit = try container.decode(String.self, forKey: .pinnedCommit)
            sourceArtifacts = try container.decodeIfPresent([FileReference].self, forKey: .sourceArtifacts) ?? [
                FileReference(path: manifestPath, kind: "corpus-manifest", format: "JSON")
            ]
            summary = try container.decode(Summary.self, forKey: .summary)
            qualification = try container.decode(QualificationResult.self, forKey: .qualification)
            toolEvidence = try container.decode(ToolEvidence.self, forKey: .toolEvidence)
            caseResults = try container.decode([CaseResult].self, forKey: .caseResults)
        }

        private static func sourceArtifacts(manifestPath: String, manifest: Manifest) -> [FileReference] {
            [
                FileReference(path: manifestPath, kind: "corpus-manifest", format: "JSON")
            ] + manifest.fixtures.map { fixture in
                FileReference(
                    path: fixture.sourcePath.isEmpty ? fixture.fileName : fixture.sourcePath,
                    kind: "spef-fixture",
                    format: "SPEF",
                    sha256: fixture.sha256,
                    byteCount: fixture.byteCount
                )
            }
        }
    }
}
