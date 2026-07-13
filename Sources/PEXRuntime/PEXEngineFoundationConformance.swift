import CircuiteFoundation
import PEXCore

extension DefaultPEXEngine {
    public func execute(_ request: PEXRunRequest) async throws -> PEXRunResult {
        try await run(request)
    }
}
