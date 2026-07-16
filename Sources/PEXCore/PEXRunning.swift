import CircuiteFoundation

/// Runs a parasitic extraction request without owning retry policy.
public protocol PEXRunning: Engine
where Request == PEXRunRequest, Output == PEXRunResult {
    func run(_ request: PEXRunRequest) async throws -> PEXRunResult

    func run(
        _ request: PEXRunRequest,
        cancellationCheck: PEXExecutionContext.CancellationCheck?
    ) async throws -> PEXRunResult
}

public extension PEXRunning {
    func execute(_ request: PEXRunRequest) async throws -> PEXRunResult {
        try await run(request)
    }

    func run(
        _ request: PEXRunRequest,
        cancellationCheck: PEXExecutionContext.CancellationCheck?
    ) async throws -> PEXRunResult {
        try await run(request)
    }
}
