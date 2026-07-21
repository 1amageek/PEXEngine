import CircuiteFoundation

public struct PEXBackendSelection: Sendable, Codable, Hashable {
    public let backendID: String
    public let executablePath: String?
    public let environmentOverrides: [String: String]
    public let expectedProducer: ProducerIdentity?

    public init(
        backendID: String,
        executablePath: String? = nil,
        environmentOverrides: [String: String] = [:],
        expectedProducer: ProducerIdentity? = nil
    ) {
        self.backendID = backendID
        self.executablePath = executablePath
        self.environmentOverrides = environmentOverrides
        self.expectedProducer = expectedProducer
    }
}
