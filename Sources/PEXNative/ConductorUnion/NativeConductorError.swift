public enum NativeConductorError: Error, Sendable, Equatable {
    case invalidInput(reason: String, sourceIDs: [String])
    case shortCircuit(sourceIDs: [String])
    case limitExceeded(NativeConductorResource)
    case cancelled
    case arithmeticOverflow
}
