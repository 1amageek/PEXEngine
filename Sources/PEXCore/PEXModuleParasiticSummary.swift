import Foundation

/// Aggregated parasitic values for the nets that belong to an instance path.
///
/// A net is included when at least one of its nodes has an instance path equal
/// to the requested module or below it in the hierarchy. Values are reported
/// in the canonical units used by `ParasiticIR`.
public struct PEXModuleParasiticSummary: Sendable, Codable, Hashable {
    public let modulePath: InstancePath
    public let cornerID: PEXCornerID
    public let netNames: [NetName]
    public let totalGroundCapF: Double
    public let totalCouplingCapF: Double
    public let totalResistanceOhm: Double
    public let nodeCount: Int
    public let elementCount: Int

    public init(
        modulePath: InstancePath,
        cornerID: PEXCornerID,
        netNames: [NetName],
        totalGroundCapF: Double,
        totalCouplingCapF: Double,
        totalResistanceOhm: Double,
        nodeCount: Int,
        elementCount: Int
    ) {
        self.modulePath = modulePath
        self.cornerID = cornerID
        self.netNames = netNames
        self.totalGroundCapF = totalGroundCapF
        self.totalCouplingCapF = totalCouplingCapF
        self.totalResistanceOhm = totalResistanceOhm
        self.nodeCount = nodeCount
        self.elementCount = elementCount
    }
}
