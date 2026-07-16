public struct PEXBackendSelection: Sendable, Codable, Hashable {
    public let backendID: String
    public let executablePath: String?
    public let environmentOverrides: [String: String]

    public init(
        backendID: String,
        executablePath: String? = nil,
        environmentOverrides: [String: String] = [:]
    ) {
        self.backendID = backendID
        self.executablePath = executablePath
        self.environmentOverrides = environmentOverrides
    }
}
