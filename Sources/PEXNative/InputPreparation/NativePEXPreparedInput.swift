import LayoutVerify

public struct NativePEXPreparedInput: Sendable {
    public let snapshot: LayoutConductorSnapshot
    public let configuration: NativePEXConfiguration
    public let netBindings: [NativePEXNetBinding]

    init(snapshot: LayoutConductorSnapshot, configuration: NativePEXConfiguration, netBindings: [NativePEXNetBinding]) {
        self.snapshot = snapshot; self.configuration = configuration; self.netBindings = netBindings
    }
}
