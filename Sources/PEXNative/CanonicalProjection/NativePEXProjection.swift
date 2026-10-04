import PEXCore

/// Canonical operators with the original physical/electrode facts and identity mapping.
public struct NativePEXProjection: Sendable {
    public let ir: ParasiticIR
    public let electrodes: NativePEXElectrodeNetwork
    public let netBindings: [NativePEXNetBinding]
    /// Ordered exactly like electrodes.network.nodes.
    public let numericNodeReferences: [NodeRef]
    /// Ordered exactly like the retained numerical/contact operator arrays.
    public let numericResistorElementIDs: [String]
    public let electrodeContactElementIDs: [String]
    public let numericCapacitorElementIDs: [String]
}
