public struct ParasiticNet: Sendable, Codable, Hashable {
    public let name: NetName
    public let nodes: [ParasiticNode]
    public let totalGroundCapF: Double
    public let totalCouplingCapF: Double
    public let totalResistanceOhm: Double

    public init(name: NetName, nodes: [ParasiticNode], totalGroundCapF: Double, totalCouplingCapF: Double, totalResistanceOhm: Double) {
        self.name = name
        self.nodes = nodes
        self.totalGroundCapF = totalGroundCapF
        self.totalCouplingCapF = totalCouplingCapF
        self.totalResistanceOhm = totalResistanceOhm
    }
}
