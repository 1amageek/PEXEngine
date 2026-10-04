import PEXCore

/// Retains the physical network and adds explicit boundary ports and finite contacts.
public struct NativePEXElectrodeNetwork: Sendable {
    public struct Port: Sendable, Equatable {
        public let pinIndex: Int
        public let terminal: NodeRef
        /// Nil denotes a physically uncontacted, isolated port.
        public let componentIndex: Int?
    }
    public struct Contact: Sendable, Equatable {
        public let portIndex: Int
        public let nodeIndex: Int
        public let face: NativePEXElectrodeFace
        public let ohms: Double
    }
    public let network: NativePEXNetwork
    public let ports: [Port]
    public let contacts: [Contact]
}
