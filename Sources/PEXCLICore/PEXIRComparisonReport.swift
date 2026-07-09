import Foundation
import PEXEngine

public struct PEXIRComparisonReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let status: String
    public let comparisonMode: String?
    public let baseline: PEXIRComparisonInput
    public let candidate: PEXIRComparisonInput
    public let thresholds: PEXIRComparisonThresholds
    public let summary: PEXIRComparisonSummary
    public let netDiffs: [PEXIRNetComparison]
    public let violations: [PEXIRComparisonViolation]

    public init(
        schemaVersion: Int = 1,
        status: String,
        comparisonMode: String? = nil,
        baseline: PEXIRComparisonInput,
        candidate: PEXIRComparisonInput,
        thresholds: PEXIRComparisonThresholds,
        summary: PEXIRComparisonSummary,
        netDiffs: [PEXIRNetComparison],
        violations: [PEXIRComparisonViolation]
    ) {
        self.schemaVersion = schemaVersion
        self.status = status
        self.comparisonMode = comparisonMode
        self.baseline = baseline
        self.candidate = candidate
        self.thresholds = thresholds
        self.summary = summary
        self.netDiffs = netDiffs
        self.violations = violations
    }
}

public struct PEXIRComparisonInput: Codable, Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let byteCount: Int
    public let cornerID: String
    public let netCount: Int
    public let elementCount: Int
    public let totalGroundCapF: Double
    public let totalCouplingCapF: Double
    public let totalCapF: Double
    public let totalResistanceOhm: Double

    public init(path: String, sha256: String, byteCount: Int, ir: ParasiticIR) {
        self.path = path
        self.sha256 = sha256
        self.byteCount = byteCount
        self.cornerID = ir.cornerID.value
        self.netCount = ir.nets.count
        self.elementCount = ir.elements.count
        self.totalGroundCapF = ir.nets.reduce(0) { $0 + $1.totalGroundCapF }
        self.totalCouplingCapF = ir.nets.reduce(0) { $0 + $1.totalCouplingCapF }
        self.totalCapF = totalGroundCapF + totalCouplingCapF
        self.totalResistanceOhm = ir.nets.reduce(0) { $0 + $1.totalResistanceOhm }
    }
}

public struct PEXIRComparisonThresholds: Codable, Sendable, Equatable {
    public let maxCapDeltaF: Double?
    public let maxCapRelativeDelta: Double?
    public let maxResistanceDeltaOhm: Double?
    public let maxResistanceRelativeDelta: Double?
    public let equivalenceValueTolerance: Double?
    public let allowNetSetChanges: Bool

    public init(
        maxCapDeltaF: Double? = nil,
        maxCapRelativeDelta: Double? = nil,
        maxResistanceDeltaOhm: Double? = nil,
        maxResistanceRelativeDelta: Double? = nil,
        equivalenceValueTolerance: Double? = nil,
        allowNetSetChanges: Bool = false
    ) {
        self.maxCapDeltaF = maxCapDeltaF
        self.maxCapRelativeDelta = maxCapRelativeDelta
        self.maxResistanceDeltaOhm = maxResistanceDeltaOhm
        self.maxResistanceRelativeDelta = maxResistanceRelativeDelta
        self.equivalenceValueTolerance = equivalenceValueTolerance
        self.allowNetSetChanges = allowNetSetChanges
    }
}

public struct PEXIRComparisonSummary: Codable, Sendable, Equatable {
    public let matchedNetCount: Int
    public let addedNetCount: Int
    public let removedNetCount: Int
    public let changedNetCount: Int
    public let violationCount: Int
    public let totalCapDeltaF: Double
    public let totalResistanceDeltaOhm: Double
    public let worstCapDeltaNet: String?
    public let worstCapDeltaF: Double
    public let worstResistanceDeltaNet: String?
    public let worstResistanceDeltaOhm: Double

    public init(
        matchedNetCount: Int,
        addedNetCount: Int,
        removedNetCount: Int,
        changedNetCount: Int,
        violationCount: Int,
        totalCapDeltaF: Double,
        totalResistanceDeltaOhm: Double,
        worstCapDeltaNet: String?,
        worstCapDeltaF: Double,
        worstResistanceDeltaNet: String?,
        worstResistanceDeltaOhm: Double
    ) {
        self.matchedNetCount = matchedNetCount
        self.addedNetCount = addedNetCount
        self.removedNetCount = removedNetCount
        self.changedNetCount = changedNetCount
        self.violationCount = violationCount
        self.totalCapDeltaF = totalCapDeltaF
        self.totalResistanceDeltaOhm = totalResistanceDeltaOhm
        self.worstCapDeltaNet = worstCapDeltaNet
        self.worstCapDeltaF = worstCapDeltaF
        self.worstResistanceDeltaNet = worstResistanceDeltaNet
        self.worstResistanceDeltaOhm = worstResistanceDeltaOhm
    }
}

public struct PEXIRNetComparison: Codable, Sendable, Equatable {
    public let netName: String
    public let status: String
    public let baseline: PEXIRNetMetrics?
    public let candidate: PEXIRNetMetrics?
    public let deltaGroundCapF: Double?
    public let deltaCouplingCapF: Double?
    public let deltaTotalCapF: Double?
    public let deltaResistanceOhm: Double?
    public let relativeTotalCapDelta: Double?
    public let relativeResistanceDelta: Double?

    public init(
        netName: String,
        status: String,
        baseline: PEXIRNetMetrics?,
        candidate: PEXIRNetMetrics?,
        deltaGroundCapF: Double?,
        deltaCouplingCapF: Double?,
        deltaTotalCapF: Double?,
        deltaResistanceOhm: Double?,
        relativeTotalCapDelta: Double?,
        relativeResistanceDelta: Double?
    ) {
        self.netName = netName
        self.status = status
        self.baseline = baseline
        self.candidate = candidate
        self.deltaGroundCapF = deltaGroundCapF
        self.deltaCouplingCapF = deltaCouplingCapF
        self.deltaTotalCapF = deltaTotalCapF
        self.deltaResistanceOhm = deltaResistanceOhm
        self.relativeTotalCapDelta = relativeTotalCapDelta
        self.relativeResistanceDelta = relativeResistanceDelta
    }
}

public struct PEXIRNetMetrics: Codable, Sendable, Equatable {
    public let nodeCount: Int
    public let totalGroundCapF: Double
    public let totalCouplingCapF: Double
    public let totalCapF: Double
    public let totalResistanceOhm: Double

    public init(net: ParasiticNet) {
        self.nodeCount = net.nodes.count
        self.totalGroundCapF = net.totalGroundCapF
        self.totalCouplingCapF = net.totalCouplingCapF
        self.totalCapF = net.totalGroundCapF + net.totalCouplingCapF
        self.totalResistanceOhm = net.totalResistanceOhm
    }
}

public struct PEXIRComparisonViolation: Codable, Sendable, Equatable {
    public let netName: String
    public let kind: String
    public let observed: Double?
    public let limit: Double?
    public let message: String

    public init(netName: String, kind: String, observed: Double?, limit: Double?, message: String) {
        self.netName = netName
        self.kind = kind
        self.observed = observed
        self.limit = limit
        self.message = message
    }
}
