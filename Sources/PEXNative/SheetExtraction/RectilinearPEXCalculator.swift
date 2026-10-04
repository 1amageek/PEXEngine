import LayoutCore
import LayoutVerify
import PEXCore

public struct RectilinearPEXCalculator: NativePEXCalculating {
    public init() {}

    public func calculate(snapshot: LayoutConductorSnapshot, technology: TechnologyIR, corner: PEXCorner,
                          layerNames: [LayoutLayerID: String], maximumCellSpanDatabaseUnits: Int32,
                          limits: NativePEXCalculationLimits = .default,
                          isCancelled: () -> Bool = { Task.isCancelled })
        throws(NativePEXCalculationError) -> NativePEXNetwork {
        let mesh = try NativePEXMesh.build(snapshot: snapshot, technology: technology, corner: corner,
            layerNames: layerNames, maximumCellSpanDatabaseUnits: maximumCellSpanDatabaseUnits,
            limits: limits, isCancelled: isCancelled)
        var calculation = try NativePEXCalculation(mesh: mesh, isCancelled: isCancelled)
        try calculation.sheetResistance(isCancelled)
        try calculation.cutResistance(isCancelled)
        try calculation.groundCapacitance(isCancelled)
        try calculation.couplingCapacitance(isCancelled)
        return try calculation.finish(isCancelled)
    }
}
