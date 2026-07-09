import Foundation
import PEXEngine

public struct PEXParseReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let status: String
    public let inputPath: String
    public let format: PEXOutputFormat
    public let cornerID: String
    public let topSubckt: String?
    public let summary: PEXParseSummary
    public let validation: PEXParseValidationReport

    public init(
        inputPath: String,
        format: PEXOutputFormat,
        cornerID: String,
        topSubckt: String?,
        ir: ParasiticIR,
        validationResult: ParasiticIRValidationResult
    ) {
        self.schemaVersion = 1
        self.status = validationResult.isValid ? "passed" : "failed"
        self.inputPath = inputPath
        self.format = format
        self.cornerID = cornerID
        self.topSubckt = topSubckt
        self.summary = PEXParseSummary(ir: ir)
        self.validation = PEXParseValidationReport(result: validationResult)
    }
}

public struct PEXParseSummary: Codable, Sendable, Equatable {
    public let netCount: Int
    public let nodeCount: Int
    public let elementCount: Int
    public let resistorCount: Int
    public let capacitorCount: Int
    public let couplingCount: Int
    public let inductorCount: Int
    public let totalGroundCapF: Double
    public let totalCouplingCapF: Double
    public let totalResistanceOhm: Double
    public let totalInductanceH: Double
    public let topNetsByCapacitance: [PEXParseNetSummary]

    public init(ir: ParasiticIR) {
        self.netCount = ir.nets.count
        self.nodeCount = ir.nets.reduce(0) { $0 + $1.nodes.count }
        self.elementCount = ir.elements.count
        self.resistorCount = ir.elements.filter { $0.kind == .resistor }.count
        self.capacitorCount = ir.elements.filter { $0.kind == .capacitor }.count
        self.couplingCount = ir.elements.filter { $0.kind == .coupling }.count
        self.inductorCount = ir.elements.filter { $0.kind == .inductor }.count
        self.totalGroundCapF = ir.nets.reduce(0) { $0 + $1.totalGroundCapF }
        self.totalCouplingCapF = ir.nets.reduce(0) { $0 + $1.totalCouplingCapF }
        self.totalResistanceOhm = ir.nets.reduce(0) { $0 + $1.totalResistanceOhm }
        self.totalInductanceH = ir.elements.filter { $0.kind == .inductor }.reduce(0) { $0 + $1.value }
        self.topNetsByCapacitance = ir.nets
            .map { PEXParseNetSummary(net: $0) }
            .sorted {
                if $0.totalCapacitanceF == $1.totalCapacitanceF {
                    return $0.name < $1.name
                }
                return $0.totalCapacitanceF > $1.totalCapacitanceF
            }
            .prefix(10)
            .map { $0 }
    }
}

public struct PEXParseNetSummary: Codable, Sendable, Equatable {
    public let name: String
    public let nodeCount: Int
    public let totalGroundCapF: Double
    public let totalCouplingCapF: Double
    public let totalCapacitanceF: Double
    public let totalResistanceOhm: Double

    public init(net: ParasiticNet) {
        self.name = net.name.value
        self.nodeCount = net.nodes.count
        self.totalGroundCapF = net.totalGroundCapF
        self.totalCouplingCapF = net.totalCouplingCapF
        self.totalCapacitanceF = net.totalGroundCapF + net.totalCouplingCapF
        self.totalResistanceOhm = net.totalResistanceOhm
    }
}

public struct PEXParseValidationReport: Codable, Sendable, Equatable {
    public let status: String
    public let errorCount: Int
    public let warningCount: Int
    public let diagnostics: [PEXParseDiagnostic]

    public init(result: ParasiticIRValidationResult) {
        self.status = result.isValid ? "passed" : "failed"
        self.errorCount = result.errors.count
        self.warningCount = result.warnings.count
        self.diagnostics = result.errors.map { PEXParseDiagnostic(error: $0) }
            + result.warnings.map { PEXParseDiagnostic(warning: $0) }
    }
}

public struct PEXParseDiagnostic: Codable, Sendable, Equatable {
    public let severity: String
    public let code: String
    public let message: String
    public let elementID: String?
    public let nodeName: String?
    public let netName: String?

    public init(error: ParasiticIRValidationError) {
        self.severity = "error"
        switch error {
        case .danglingNodeReference(let elementID, let nodeName):
            self.code = "dangling_node_reference"
            self.message = "Element \(elementID) references unknown node \(nodeName)."
            self.elementID = elementID
            self.nodeName = nodeName
            self.netName = nil
        case .duplicateElementID(let elementID):
            self.code = "duplicate_element_id"
            self.message = "Element ID \(elementID) appears more than once."
            self.elementID = elementID
            self.nodeName = nil
            self.netName = nil
        case .invalidValue(let elementID, let value, let reason):
            self.code = "invalid_value"
            self.message = "Element \(elementID) has invalid value \(value): \(reason)."
            self.elementID = elementID
            self.nodeName = nil
            self.netName = nil
        case .inconsistentNetMembership(let node, let claimedNet, let actualNet):
            self.code = "inconsistent_net_membership"
            self.message = "Node \(node) is claimed on \(claimedNet) but belongs to \(actualNet)."
            self.elementID = nil
            self.nodeName = node
            self.netName = claimedNet
        case .ambiguousGroundCapacitor(let elementID):
            self.code = "ambiguous_ground_capacitor"
            self.message = "Coupling element \(elementID) is missing its second endpoint."
            self.elementID = elementID
            self.nodeName = nil
            self.netName = nil
        case .missingEndpoint(let elementID, let kind):
            self.code = "missing_endpoint"
            self.message = "Element \(elementID) of kind \(kind.rawValue) is missing a required endpoint."
            self.elementID = elementID
            self.nodeName = nil
            self.netName = nil
        }
    }

    public init(warning: ParasiticIRValidationWarning) {
        self.severity = "warning"
        switch warning {
        case .disconnectedNode(let nodeName):
            self.code = "disconnected_node"
            self.message = "Node \(nodeName) is not referenced by any parasitic element."
            self.elementID = nil
            self.nodeName = nodeName
            self.netName = nil
        case .suspiciousValue(let elementID, let value, let reason):
            self.code = "suspicious_value"
            self.message = "Element \(elementID) has suspicious value \(value): \(reason)."
            self.elementID = elementID
            self.nodeName = nil
            self.netName = nil
        case .emptyNet(let netName):
            self.code = "empty_net"
            self.message = "Net \(netName) contains no nodes."
            self.elementID = nil
            self.nodeName = nil
            self.netName = netName
        }
    }
}
