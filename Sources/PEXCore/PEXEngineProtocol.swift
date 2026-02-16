public protocol PEXEngineProtocol: Sendable {
    func run(_ request: PEXRunRequest) async throws -> PEXRunResult
}
