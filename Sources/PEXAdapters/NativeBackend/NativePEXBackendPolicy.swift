/// Observed admission/cancellation policy, separate from physical model identity.
public struct NativePEXBackendPolicy: Sendable, Codable, Equatable {
    public let maximumLayoutBytes: Int
    public let maximumCodeImageBytes: Int
    public let maximumEvidenceBytes: Int
    public let cancellationPollSeconds: Int64
    public let cancellationPollAttoseconds: Int64

    init(adapter: NativePEXAdapter) {
        maximumLayoutBytes = adapter.maximumLayoutBytes
        maximumCodeImageBytes = adapter.maximumCodeImageBytes
        maximumEvidenceBytes = adapter.maximumEvidenceBytes
        cancellationPollSeconds = adapter.cancellationPollInterval.components.seconds
        cancellationPollAttoseconds = adapter.cancellationPollInterval.components.attoseconds
    }
}
