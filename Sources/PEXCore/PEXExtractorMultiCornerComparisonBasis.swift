/// Describes the evidence basis for interpreting a multi-corner PEX spread.
///
/// A comparable numeric spread does not by itself prove that all corners are
/// PVT variants of one technology. Consumers must inspect this value before
/// using a spread as a PVT signoff metric.
public enum PEXExtractorMultiCornerComparisonBasis: String, Sendable, Codable, Hashable {
    /// Every corner uses the run-level technology reference.
    case sharedTechnology
    /// At least one corner uses an explicit technology override.
    case perCornerTechnology
    /// The persisted artifact predates this field or does not expose enough
    /// metadata to establish the comparison basis.
    case unknown
}
