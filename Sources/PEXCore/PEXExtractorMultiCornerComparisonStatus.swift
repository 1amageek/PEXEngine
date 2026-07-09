public enum PEXExtractorMultiCornerComparisonStatus: String, Sendable, Codable, Hashable {
    case comparable
    case singleCorner
    case partialFailure
    case noSuccessfulCorners
}
