import LayoutVerify

public struct NativePEXPreparedInput: Sendable {
    public let snapshot: LayoutConductorSnapshot
    public let configuration: NativePEXConfiguration

    init(snapshot: LayoutConductorSnapshot, configuration: NativePEXConfiguration) {
        self.snapshot = snapshot; self.configuration = configuration
    }
}
