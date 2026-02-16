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

    public static func mock() -> Self {
        PEXBackendSelection(
            backendID: "mock",
            executablePath: nil,
            environmentOverrides: [:]
        )
    }
}
