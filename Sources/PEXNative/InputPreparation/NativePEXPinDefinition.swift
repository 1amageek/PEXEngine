import LayoutCore

/// Explicit source-cell pin metadata; it never replaces conductor geometry.
public struct NativePEXPinDefinition: Sendable, Equatable, Codable {
    public let cellName: String
    public let pin: LayoutPin

    public init(cellName: String, pin: LayoutPin) {
        self.cellName = cellName; self.pin = pin
    }
}
