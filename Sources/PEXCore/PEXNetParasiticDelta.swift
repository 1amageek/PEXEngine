import Foundation

public struct PEXNetParasiticDelta: Sendable, Codable, Hashable {
    public let netName: NetName
    public let groundCapDeltaF: Double
    public let couplingCapDeltaF: Double
    public let resistanceDeltaOhm: Double
    public let baseNodeCount: Int
    public let targetNodeCount: Int

    public init(
        netName: NetName,
        groundCapDeltaF: Double,
        couplingCapDeltaF: Double,
        resistanceDeltaOhm: Double,
        baseNodeCount: Int,
        targetNodeCount: Int
    ) {
        self.netName = netName
        self.groundCapDeltaF = groundCapDeltaF
        self.couplingCapDeltaF = couplingCapDeltaF
        self.resistanceDeltaOhm = resistanceDeltaOhm
        self.baseNodeCount = baseNodeCount
        self.targetNodeCount = targetNodeCount
    }
}
