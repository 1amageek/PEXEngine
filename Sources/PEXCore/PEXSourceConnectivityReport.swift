import Foundation

public enum PEXSourceConnectivityStatus: String, Sendable, Codable, Hashable {
    case passed
    case warning
    case failed
    case notApplicable
}

public struct PEXSourceConnectivityReport: Sendable, Codable, Hashable {
    public let status: PEXSourceConnectivityStatus
    public let sourceNetlistFormat: NetlistFormat
    public let sourceNodeCount: Int
    public let extractedPinNodeCount: Int
    public let matchedPinNodeCount: Int
    public let unmatchedExtractedPinNodes: [String]
    public let sourceOnlyNodes: [String]
    public let diagnostics: [String]

    public init(
        status: PEXSourceConnectivityStatus,
        sourceNetlistFormat: NetlistFormat,
        sourceNodeCount: Int,
        extractedPinNodeCount: Int,
        matchedPinNodeCount: Int,
        unmatchedExtractedPinNodes: [String] = [],
        sourceOnlyNodes: [String] = [],
        diagnostics: [String] = []
    ) {
        self.status = status
        self.sourceNetlistFormat = sourceNetlistFormat
        self.sourceNodeCount = sourceNodeCount
        self.extractedPinNodeCount = extractedPinNodeCount
        self.matchedPinNodeCount = matchedPinNodeCount
        self.unmatchedExtractedPinNodes = Array(Set(unmatchedExtractedPinNodes)).sorted()
        self.sourceOnlyNodes = Array(Set(sourceOnlyNodes)).sorted()
        self.diagnostics = Array(Set(diagnostics)).sorted()
    }

    public var isSatisfied: Bool {
        status == .passed || status == .notApplicable
    }
}
