public protocol PEXAdapter: Sendable {
    var backendID: String { get }
    var capabilities: PEXBackendCapabilities { get }
    func prepare(_ context: PEXExecutionContext) async throws
    func execute(_ context: PEXExecutionContext) async throws -> PEXRawOutput
    func cleanup(_ context: PEXExecutionContext) async
}
