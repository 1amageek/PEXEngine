import PEXCore
import PEXNative

struct NativePEXTerminalEvidence: Encodable {
    let version = 1
    let policy: NativePEXBackendPolicy
    let status: String
    let phase: String
    let cornerID: PEXCornerID
    let image: NativePEXCodeImage?
    let executionIdentity: PEXBackendExecutionIdentity?
    let failure: String?
}
