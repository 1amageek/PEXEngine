public protocol PEXAdapterReadinessProviding: Sendable {
    func toolReadiness(processProfile: PEXProcessProfileReference?) -> PEXExtractorToolReadiness
}
