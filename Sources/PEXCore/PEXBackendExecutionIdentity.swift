import CircuiteFoundation

/// The measured identity of one backend process invocation.
///
/// External backends must construct this value from the executable bytes and
/// version output observed for the same process image used by the extraction.
public struct PEXBackendExecutionIdentity: Sendable, Codable, Hashable {
    public let producer: ProducerIdentity
    public let binaryDigest: ContentDigest
    public let invocation: ExecutionInvocation
    public let environment: ExecutionEnvironmentFingerprint

    public init(
        producer: ProducerIdentity,
        binaryDigest: ContentDigest,
        invocation: ExecutionInvocation,
        environment: ExecutionEnvironmentFingerprint
    ) throws {
        guard binaryDigest.algorithm == .sha256 else {
            throw PEXError.invalidInput("PEX backend executable identity requires a SHA-256 digest")
        }
        guard producer.build?.caseInsensitiveCompare(binaryDigest.hexadecimalValue) == .orderedSame else {
            throw PEXError.invalidInput(
                "PEX backend producer build must equal the measured executable SHA-256 digest"
            )
        }
        self.producer = producer
        self.binaryDigest = binaryDigest
        self.invocation = invocation
        self.environment = environment
    }
}
