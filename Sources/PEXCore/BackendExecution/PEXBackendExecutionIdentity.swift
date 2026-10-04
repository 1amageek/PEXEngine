import CircuiteFoundation

/// The measured identity of a backend code image and its actual invocation mode.
///
/// External backends measure their executable and version output. In-process
/// backends measure the loaded implementation image and use a Foundation
/// in-process entry point; neither mode is inferred from the output format.
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
            throw PEXError.invalidInput("PEX backend code-image identity requires a SHA-256 digest")
        }
        guard producer.build?.caseInsensitiveCompare(binaryDigest.hexadecimalValue) == .orderedSame else {
            throw PEXError.invalidInput(
                "PEX backend producer build must equal the measured code-image SHA-256 digest"
            )
        }
        self.producer = producer
        self.binaryDigest = binaryDigest
        self.invocation = invocation
        self.environment = environment
    }
    private enum CodingKeys: String, CodingKey { case producer, binaryDigest, invocation, environment }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(producer: container.decode(ProducerIdentity.self, forKey: .producer),
                      binaryDigest: container.decode(ContentDigest.self, forKey: .binaryDigest),
                      invocation: container.decode(ExecutionInvocation.self, forKey: .invocation),
                      environment: container.decode(ExecutionEnvironmentFingerprint.self, forKey: .environment))
    }

}
