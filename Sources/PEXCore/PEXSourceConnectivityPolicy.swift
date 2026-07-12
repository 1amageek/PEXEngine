public enum PEXSourceConnectivityPolicy: String, Sendable, Codable, Hashable, CaseIterable {
    case disabled
    case warn
    case strict
}
