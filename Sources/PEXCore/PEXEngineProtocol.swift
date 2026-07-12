public protocol PEXEngineProtocol: Sendable {
    func run(_ request: PEXRunRequest) async throws -> PEXRunResult

    /// Re-executes only failed corners from a prior partial/failed run and
    /// records the prior run ID in the new manifest for auditability.
    func retryFailedCorners(
        _ request: PEXRunRequest,
        from previousResult: PEXRunResult
    ) async throws -> PEXRunResult
}
