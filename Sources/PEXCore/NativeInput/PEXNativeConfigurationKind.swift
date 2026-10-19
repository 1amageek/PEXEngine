/// Selects a native source law explicitly; configuration decoding never guesses from layout bytes.
public enum PEXNativeConfigurationKind: String, Sendable, Codable, Hashable {
    case maskGeometry
    case routedOpenRCXV1
}
