public enum NativeRoutedPEXPreparationError: Error, Sendable, Equatable {
    case invalidConfiguration(String)
    case sourceMismatch(String)
    case missingSource(String)
    case unsupportedSource(String)
    case sourceDecode(String)
    case limitExceeded(String)
    case cancelled
    case arithmeticOverflow
}
