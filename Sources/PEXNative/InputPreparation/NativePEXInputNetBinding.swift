import PEXCore

/// Explicit durable source authority and its injective canonical output name.
public struct NativePEXInputNetBinding: Sendable, Equatable, Codable {
    public let selector: NativePEXInputNetSelector
    public let netName: NetName

    public init(selector: NativePEXInputNetSelector, netName: NetName) {
        self.selector = selector
        self.netName = netName
    }
}
