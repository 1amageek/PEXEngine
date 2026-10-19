import PEXCore

/// An R-only numerical network; contact cells implement an explicit ideal equipotential region.
public struct NativeSheetResistanceResult: Sendable {
    public struct Cell: Sendable, Equatable {
        public let netName: NetName
        public let layerName: String
        public let rect: NativeConductorUnion.Rect
        public let nodeIndex: Int
        public let contributorIndices: [Int]
    }
    public struct Node: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case sheet, contact, cut(sourceID: String) }
        public let kind: Kind
        public let netName: NetName
        public let layerName: String?
    }
    public struct Resistor: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case sheet, contact, cut(sourceID: String) }
        public let kind: Kind
        public let nodeA: Int
        public let nodeB: Int
        public let ohms: Double
        public let contributorIndices: [Int]
    }
    public struct TerminalAssignment: Sendable, Equatable {
        public let ref: NodeRef
        public let nodeIndex: Int
        public let cellIndices: [Int]
    }
    public let input: NativeSheetResistanceInput
    public let conductorUnion: NativeConductorUnion
    public let maximumCellSpanDatabaseUnits: Int32
    public let cells: [Cell]
    public let nodes: [Node]
    public let resistors: [Resistor]
    public let terminalAssignments: [TerminalAssignment]
    public let usage: [NativeConductorResource: Int]
}
