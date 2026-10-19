import PEXCore

public enum NativeSheetResistanceError: Error, Sendable, Equatable {
    case conductor(NativeConductorError)
    case invalidConfiguration
    case invalidInput(reason: String)
    case disconnectedTerminal(NodeRef)
    case missingTerminalContact(NodeRef)
    case incompleteCutContact(sourceID: String)
    case numericFailure
}
