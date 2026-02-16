public struct PEXBackendCapabilities: Sendable, Codable, Hashable {
    public let supportsCouplingCaps: Bool
    public let supportsCornerSweep: Bool
    public let supportsIncremental: Bool
    public let supportsRCReduction: Bool
    public let nativeOutputFormats: [PEXOutputFormat]

    public init(
        supportsCouplingCaps: Bool,
        supportsCornerSweep: Bool,
        supportsIncremental: Bool,
        supportsRCReduction: Bool,
        nativeOutputFormats: [PEXOutputFormat]
    ) {
        self.supportsCouplingCaps = supportsCouplingCaps
        self.supportsCornerSweep = supportsCornerSweep
        self.supportsIncremental = supportsIncremental
        self.supportsRCReduction = supportsRCReduction
        self.nativeOutputFormats = nativeOutputFormats
    }
}
