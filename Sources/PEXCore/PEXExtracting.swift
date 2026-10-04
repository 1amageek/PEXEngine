import Foundation
import CircuiteFoundation

public protocol PEXExtracting: Sendable {
    var backendID: String { get }
    var capabilities: PEXBackendCapabilities { get }
    func prepare(_ context: PEXExecutionContext) async throws
    func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult
    func cleanup(_ context: PEXExecutionContext) async
}
