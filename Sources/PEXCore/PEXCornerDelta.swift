import Foundation

/// Per-net and aggregate change between two persisted extraction corners.
public struct PEXCornerDelta: Sendable, Codable, Hashable {
    public let baseCornerID: PEXCornerID
    public let targetCornerID: PEXCornerID
    public let totalGroundCapDeltaF: Double
    public let totalCouplingCapDeltaF: Double
    public let totalResistanceDeltaOhm: Double
    public let netDeltas: [PEXNetParasiticDelta]

    public init(
        baseCornerID: PEXCornerID,
        targetCornerID: PEXCornerID,
        totalGroundCapDeltaF: Double,
        totalCouplingCapDeltaF: Double,
        totalResistanceDeltaOhm: Double,
        netDeltas: [PEXNetParasiticDelta]
    ) {
        self.baseCornerID = baseCornerID
        self.targetCornerID = targetCornerID
        self.totalGroundCapDeltaF = totalGroundCapDeltaF
        self.totalCouplingCapDeltaF = totalCouplingCapDeltaF
        self.totalResistanceDeltaOhm = totalResistanceDeltaOhm
        self.netDeltas = netDeltas
    }
}
