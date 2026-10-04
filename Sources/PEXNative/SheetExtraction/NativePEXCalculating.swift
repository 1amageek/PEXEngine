import LayoutCore
import LayoutVerify
import PEXCore

public protocol NativePEXCalculating: Sendable {
    func calculate(snapshot: LayoutConductorSnapshot, technology: TechnologyIR, corner: PEXCorner,
                   layerNames: [LayoutLayerID: String], maximumCellSpanDatabaseUnits: Int32,
                   limits: NativePEXCalculationLimits, isCancelled: () -> Bool)
        throws(NativePEXCalculationError) -> NativePEXNetwork
}
