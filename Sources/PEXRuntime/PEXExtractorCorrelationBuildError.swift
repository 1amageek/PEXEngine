import Foundation

public enum PEXExtractorCorrelationBuildError: Error, LocalizedError, Sendable, Hashable {
    case invalidCorrelationID(String)
    case invalidReport(backendID: String, reason: String)
    case identicalBackend(String)
    case reportNotPassed(backendID: String)
    case caseSetMismatch
    case corpusCaseMismatch(caseID: String)
    case caseNotPassed(caseID: String, backendID: String)
    case expectedMetricMismatch(caseID: String, metricID: String)
    case missingMetric(caseID: String, metricID: String, backendID: String)
    case noComparableMetrics(caseID: String)

    public var errorDescription: String? {
        switch self {
        case .invalidCorrelationID(let correlationID):
            "Extractor correlation ID is invalid: '\(correlationID)'."
        case .invalidReport(let backendID, let reason):
            "Extractor report for '\(backendID)' is invalid: \(reason)"
        case .identicalBackend(let backend):
            "Extractor correlation requires distinct backend identifiers; both reports use '\(backend)'. Implementation independence is evaluated by ToolQualification."
        case .reportNotPassed(let backendID):
            "Extractor report for '\(backendID)' is not a passing corpus report."
        case .caseSetMismatch:
            "Primary and oracle extractor reports do not contain the same case set."
        case .corpusCaseMismatch(let caseID):
            "Extractor reports do not match the canonical corpus declaration for case '\(caseID)'."
        case .caseNotPassed(let caseID, let backendID):
            "Extractor case '\(caseID)' did not pass for backend '\(backendID)'."
        case .expectedMetricMismatch(let caseID, let metricID):
            "Extractor case '\(caseID)' has inconsistent expectation or tolerance for '\(metricID)'."
        case .missingMetric(let caseID, let metricID, let backendID):
            "Extractor case '\(caseID)' is missing observed metric '\(metricID)' for backend '\(backendID)'."
        case .noComparableMetrics(let caseID):
            "Extractor case '\(caseID)' has no comparable expected physical metrics."
        }
    }
}
