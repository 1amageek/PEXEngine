import LayoutVerify
import PEXCore

/// Finite-volume state nodes and operators, retaining the exact admitted inputs.
/// Pins are incidence facts; this value does not impose terminal electrode conditions.
public struct NativePEXNetwork: Sendable {
    public struct Node: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case metal, cut(viaName: String) }
        public let kind: Kind
        public let layerName: String
        public let componentIndex: Int
        public let minXDatabaseUnits: Int32
        public let maxXDatabaseUnits: Int32
        public let minYDatabaseUnits: Int32
        public let maxYDatabaseUnits: Int32
        public let heightMeters: Double
    }
    public struct Resistor: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case sheet, cut }
        public let kind: Kind
        public let nodeA: Int
        public let nodeB: Int
        public let ohms: Double
    }
    public struct Capacitor: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case ground, coplanar, interlayer }
        public let kind: Kind
        public let nodeA: Int
        /// Nil denotes the model's explicit reference node.
        public let nodeB: Int?
        public let farads: Double
    }
    public struct PinContact: Sendable, Equatable {
        public let pinIndex: Int
        public let nodeIndices: [Int]
    }
    public let snapshot: LayoutConductorSnapshot
    public let model: PEXElectricalModel
    public let metersPerDatabaseUnit: Double
    public let maximumCellSpanDatabaseUnits: Int32
    public let nodes: [Node]
    public let resistors: [Resistor]
    public let capacitors: [Capacitor]
    public let pinContacts: [PinContact]
}
