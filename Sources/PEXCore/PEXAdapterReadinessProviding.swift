public protocol PEXAdapterReadinessProviding: Sendable {
    func toolReadiness(processProfile: PEXProcessProfileReference?) -> PEXExtractorToolReadiness

    /// Returns whether the adapter can execute the requested corners without
    /// silently reusing one physical extraction table.
    func supportsCornerSweep(
        corners: [PEXCorner],
        processProfile: PEXProcessProfileReference?
    ) -> Bool
}

public extension PEXAdapterReadinessProviding {
    func supportsCornerSweep(
        corners: [PEXCorner],
        processProfile: PEXProcessProfileReference?
    ) -> Bool {
        false
    }
}
