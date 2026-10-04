import PEXCore

/// An exact captured pin and its explicitly requested source terminal/electrode.
public struct NativePEXElectrodeBinding: Sendable, Equatable, Codable {
    public let pinIndex: Int
    public let terminal: NodeRef
    public let faces: [NativePEXElectrodeFace]

    public init(pinIndex: Int, terminal: NodeRef, faces: [NativePEXElectrodeFace]) {
        self.pinIndex = pinIndex; self.terminal = terminal; self.faces = faces
    }
}
