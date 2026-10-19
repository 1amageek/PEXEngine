import PEXCore

public enum NativeRoutedRuleError: Error, Sendable, Equatable {
    case invalidModel(PEXOpenRCXSourceError)
    case invalidQuery
    case unavailableContext
    case emptyActiveTable
    case resistanceOnlyContext
    case unrepresentableArithmetic
    case limitExceeded
    case cancelled
}
