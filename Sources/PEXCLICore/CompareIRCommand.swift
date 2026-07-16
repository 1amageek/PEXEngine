import CryptoKit
import Foundation
import CircuiteFoundation
import PEXEngine

public struct CompareIRCommand: Sendable {
    public let baselinePath: String
    public let candidatePath: String
    public let reportPath: String?
    public let jsonOutput: Bool
    public let equivalenceMode: Bool
    public let thresholds: PEXIRComparisonThresholds

    public init(arguments: [String]) throws {
        let parsed = try CompareIRCommandArguments(arguments: arguments)
        self.baselinePath = parsed.baselinePath
        self.candidatePath = parsed.candidatePath
        self.reportPath = parsed.reportPath
        self.jsonOutput = parsed.jsonOutput
        self.equivalenceMode = parsed.equivalenceMode
        self.thresholds = parsed.thresholds
    }

    public func run() async throws -> Bool {
        let report = try compare()
        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("PEX IR comparison: \(report.status)")
            print("Baseline: \(report.baseline.artifact.path)")
            print("Candidate: \(report.candidate.artifact.path)")
            print("Matched nets: \(report.summary.matchedNetCount)")
            print("Added nets: \(report.summary.addedNetCount)")
            print("Removed nets: \(report.summary.removedNetCount)")
            print("Violations: \(report.summary.violationCount)")
            print("Total capacitance delta: \(report.summary.totalCapDeltaF)F")
            print("Total resistance delta: \(report.summary.totalResistanceDeltaOhm)Ohm")
            if let reportPath {
                print("Report: \(reportPath)")
            }
        }
        return report.status == "passed"
    }

    public func compare() throws -> PEXIRComparisonReport {
        let baselineURL = URL(filePath: baselinePath)
        let candidateURL = URL(filePath: candidatePath)
        let baseline = try readIR(url: baselineURL, role: "baseline")
        let candidate = try readIR(url: candidateURL, role: "candidate")
        try validateIR(baseline.ir)
        try validateIR(candidate.ir)
        let netComparison = buildNetComparison(baselineIR: baseline.ir, candidateIR: candidate.ir)
        let semanticViolations = makeSemanticViolationsIfNeeded(baselineIR: baseline.ir, candidateIR: candidate.ir)
        let report = try makeReport(
            baselineURL: baselineURL,
            baselineData: baseline.data,
            baselineIR: baseline.ir,
            candidateURL: candidateURL,
            candidateData: candidate.data,
            candidateIR: candidate.ir,
            netComparison: netComparison,
            semanticViolations: semanticViolations
        )
        try writeReportIfRequested(report)
        return report
    }

    private func validateIR(_ ir: ParasiticIR) throws {
        let validation = ParasiticIRValidator().validate(ir)
        guard validation.isValid else {
            throw PEXError.irValidationFailed(cornerID: ir.cornerID, errors: validation.errors)
        }
    }

    private func buildNetComparison(
        baselineIR: ParasiticIR,
        candidateIR: ParasiticIR
    ) -> PEXIRNetComparisonAccumulator {
        var accumulator = PEXIRNetComparisonAccumulator(thresholds: thresholds, equivalenceMode: equivalenceMode)
        let baselineByNet = Dictionary(uniqueKeysWithValues: baselineIR.nets.map { ($0.name.value, $0) })
        let candidateByNet = Dictionary(uniqueKeysWithValues: candidateIR.nets.map { ($0.name.value, $0) })
        let netNames = Set(baselineByNet.keys).union(candidateByNet.keys).sorted()
        for netName in netNames {
            accumulator.record(netName: netName, baseline: baselineByNet[netName], candidate: candidateByNet[netName])
        }
        return accumulator
    }

    private func makeSemanticViolationsIfNeeded(
        baselineIR: ParasiticIR,
        candidateIR: ParasiticIR
    ) -> [PEXIRComparisonViolation] {
        guard equivalenceMode else { return [] }
        return PEXIRSemanticComparator(
            valueAbsTolerance: thresholds.equivalenceValueTolerance ?? 1e-21
        ).compare(baseline: baselineIR, candidate: candidateIR)
    }

    private func makeReport(
        baselineURL: URL,
        baselineData: Data,
        baselineIR: ParasiticIR,
        candidateURL: URL,
        candidateData: Data,
        candidateIR: ParasiticIR,
        netComparison: PEXIRNetComparisonAccumulator,
        semanticViolations: [PEXIRComparisonViolation]
    ) throws -> PEXIRComparisonReport {
        let baselineInput = try makeInput(url: baselineURL, data: baselineData, ir: baselineIR)
        let candidateInput = try makeInput(url: candidateURL, data: candidateData, ir: candidateIR)
        let violations = netComparison.violations + semanticViolations
        return PEXIRComparisonReport(
            status: violations.isEmpty ? "passed" : "failed",
            comparisonMode: equivalenceMode ? "equivalence" : "regression",
            baseline: baselineInput,
            candidate: candidateInput,
            thresholds: thresholds,
            summary: netComparison.summary(
                baselineInput: baselineInput,
                candidateInput: candidateInput,
                violationCount: violations.count
            ),
            netDiffs: netComparison.diffs,
            violations: violations
        )
    }

    private func makeInput(url: URL, data: Data, ir: ParasiticIR) throws -> PEXIRComparisonInput {
        PEXIRComparisonInput(
            artifact: ArtifactReference(
                locator: ArtifactLocator(
                    location: try ArtifactLocation(fileURL: url),
                    role: .input,
                    kind: .parasitics,
                    format: .json
                ),
                digest: try ContentDigest(
                    algorithm: .sha256,
                    hexadecimalValue: Self.sha256Hex(data)
                ),
                byteCount: UInt64(data.count)
            ),
            ir: ir
        )
    }

    private func readIR(url: URL, role: String) throws -> (data: Data, ir: ParasiticIR) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PEXError.invalidInput("Failed to read \(role) ParasiticIR JSON at \(url.path(percentEncoded: false)): \(error)")
        }
        do {
            return (data, try JSONDecoder().decode(ParasiticIR.self, from: data))
        } catch {
            throw PEXError.invalidInput("Failed to decode \(role) ParasiticIR JSON at \(url.path(percentEncoded: false)): \(error)")
        }
    }

    private func writeReportIfRequested(_ report: PEXIRComparisonReport) throws {
        guard let reportPath else {
            return
        }
        let reportURL = URL(filePath: reportPath)
        do {
            try FileManager.default.createDirectory(
                at: reportURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: [.atomic])
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to write PEX IR comparison report to \(reportURL.path(percentEncoded: false))",
                underlying: error
            )
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct PEXIRNetComparisonAccumulator {
    let thresholds: PEXIRComparisonThresholds
    let equivalenceMode: Bool
    private(set) var diffs: [PEXIRNetComparison] = []
    private(set) var violations: [PEXIRComparisonViolation] = []
    private var matchedNetCount = 0
    private var addedNetCount = 0
    private var removedNetCount = 0
    private var changedNetCount = 0
    private var worstCapDeltaNet: String?
    private var worstCapDeltaF = 0.0
    private var worstResistanceDeltaNet: String?
    private var worstResistanceDeltaOhm = 0.0

    init(thresholds: PEXIRComparisonThresholds, equivalenceMode: Bool) {
        self.thresholds = thresholds
        self.equivalenceMode = equivalenceMode
    }

    mutating func record(netName: String, baseline: ParasiticNet?, candidate: ParasiticNet?) {
        let baselineMetrics = baseline.map(PEXIRNetMetrics.init(net:))
        let candidateMetrics = candidate.map(PEXIRNetMetrics.init(net:))
        let comparison = compare(netName: netName, baseline: baselineMetrics, candidate: candidateMetrics)
        guard let comparison else { return }
        diffs.append(comparison)
    }

    func summary(
        baselineInput: PEXIRComparisonInput,
        candidateInput: PEXIRComparisonInput,
        violationCount: Int
    ) -> PEXIRComparisonSummary {
        PEXIRComparisonSummary(
            matchedNetCount: matchedNetCount,
            addedNetCount: addedNetCount,
            removedNetCount: removedNetCount,
            changedNetCount: changedNetCount,
            violationCount: violationCount,
            totalCapDeltaF: candidateInput.totalCapF - baselineInput.totalCapF,
            totalResistanceDeltaOhm: candidateInput.totalResistanceOhm - baselineInput.totalResistanceOhm,
            worstCapDeltaNet: worstCapDeltaNet,
            worstCapDeltaF: worstCapDeltaF,
            worstResistanceDeltaNet: worstResistanceDeltaNet,
            worstResistanceDeltaOhm: worstResistanceDeltaOhm
        )
    }

    private mutating func compare(
        netName: String,
        baseline: PEXIRNetMetrics?,
        candidate: PEXIRNetMetrics?
    ) -> PEXIRNetComparison? {
        switch (baseline, candidate) {
        case (.some(let base), .some(let cand)):
            return compareMatchedNet(netName: netName, baseline: base, candidate: cand)
        case (.none, .some):
            addedNetCount += 1
            appendNetSetViolationIfNeeded(netName: netName, kind: "net_added")
            return makeNetSetComparison(netName: netName, status: "added", candidate: candidate)
        case (.some, .none):
            removedNetCount += 1
            appendNetSetViolationIfNeeded(netName: netName, kind: "net_removed")
            return makeNetSetComparison(netName: netName, status: "removed", baseline: baseline)
        case (.none, .none):
            return nil
        }
    }

    private mutating func compareMatchedNet(
        netName: String,
        baseline: PEXIRNetMetrics,
        candidate: PEXIRNetMetrics
    ) -> PEXIRNetComparison {
        matchedNetCount += 1
        let deltas = PEXIRNetComparisonDeltas(baseline: baseline, candidate: candidate)
        if deltas.status == "changed" {
            changedNetCount += 1
        }
        if !equivalenceMode {
            appendThresholdViolations(netName: netName, deltas: deltas)
        }
        recordWorstDeltas(netName: netName, deltas: deltas)
        return PEXIRNetComparison(
            netName: netName,
            status: deltas.status,
            baseline: baseline,
            candidate: candidate,
            deltaGroundCapF: deltas.groundCapF,
            deltaCouplingCapF: deltas.couplingCapF,
            deltaTotalCapF: deltas.totalCapF,
            deltaResistanceOhm: deltas.resistanceOhm,
            relativeTotalCapDelta: deltas.relativeTotalCapDelta,
            relativeResistanceDelta: deltas.relativeResistanceDelta
        )
    }

    private func makeNetSetComparison(
        netName: String,
        status: String,
        baseline: PEXIRNetMetrics? = nil,
        candidate: PEXIRNetMetrics? = nil
    ) -> PEXIRNetComparison {
        PEXIRNetComparison(
            netName: netName,
            status: status,
            baseline: baseline,
            candidate: candidate,
            deltaGroundCapF: nil,
            deltaCouplingCapF: nil,
            deltaTotalCapF: nil,
            deltaResistanceOhm: nil,
            relativeTotalCapDelta: nil,
            relativeResistanceDelta: nil
        )
    }

    private mutating func appendNetSetViolationIfNeeded(netName: String, kind: String) {
        guard !thresholds.allowNetSetChanges, !equivalenceMode else { return }
        let message = kind == "net_added"
            ? "Candidate IR contains a net that is absent from the baseline IR."
            : "Candidate IR is missing a net that exists in the baseline IR."
        violations.append(PEXIRComparisonViolation(
            netName: netName,
            kind: kind,
            observed: nil,
            limit: nil,
            message: message
        ))
    }

    private mutating func appendThresholdViolations(netName: String, deltas: PEXIRNetComparisonDeltas) {
        appendViolationIfExceeded(netName: netName, kind: "capacitance_absolute_regression", observed: deltas.totalCapF, limit: thresholds.maxCapDeltaF)
        appendViolationIfExceeded(netName: netName, kind: "capacitance_relative_regression", observed: deltas.relativeTotalCapDelta, limit: thresholds.maxCapRelativeDelta)
        appendViolationIfExceeded(netName: netName, kind: "resistance_absolute_regression", observed: deltas.resistanceOhm, limit: thresholds.maxResistanceDeltaOhm)
        appendViolationIfExceeded(netName: netName, kind: "resistance_relative_regression", observed: deltas.relativeResistanceDelta, limit: thresholds.maxResistanceRelativeDelta)
    }

    private mutating func appendViolationIfExceeded(
        netName: String,
        kind: String,
        observed: Double?,
        limit: Double?
    ) {
        guard let observed, let limit, observed > limit else { return }
        violations.append(PEXIRComparisonViolation(
            netName: netName,
            kind: kind,
            observed: observed,
            limit: limit,
            message: violationMessage(for: kind)
        ))
    }

    private func violationMessage(for kind: String) -> String {
        switch kind {
        case "capacitance_absolute_regression":
            return "Candidate total capacitance increased beyond the absolute tolerance."
        case "capacitance_relative_regression":
            return "Candidate total capacitance increased beyond the relative tolerance."
        case "resistance_absolute_regression":
            return "Candidate total resistance increased beyond the absolute tolerance."
        case "resistance_relative_regression":
            return "Candidate total resistance increased beyond the relative tolerance."
        default:
            return "Candidate IR exceeded the comparison tolerance."
        }
    }

    private mutating func recordWorstDeltas(netName: String, deltas: PEXIRNetComparisonDeltas) {
        if deltas.totalCapF > worstCapDeltaF {
            worstCapDeltaF = deltas.totalCapF
            worstCapDeltaNet = netName
        }
        if deltas.resistanceOhm > worstResistanceDeltaOhm {
            worstResistanceDeltaOhm = deltas.resistanceOhm
            worstResistanceDeltaNet = netName
        }
    }
}

private struct PEXIRNetComparisonDeltas {
    let groundCapF: Double
    let couplingCapF: Double
    let totalCapF: Double
    let resistanceOhm: Double
    let relativeTotalCapDelta: Double?
    let relativeResistanceDelta: Double?

    var status: String {
        totalCapF == 0 && resistanceOhm == 0 ? "unchanged" : "changed"
    }

    init(baseline: PEXIRNetMetrics, candidate: PEXIRNetMetrics) {
        self.groundCapF = candidate.totalGroundCapF - baseline.totalGroundCapF
        self.couplingCapF = candidate.totalCouplingCapF - baseline.totalCouplingCapF
        self.totalCapF = candidate.totalCapF - baseline.totalCapF
        self.resistanceOhm = candidate.totalResistanceOhm - baseline.totalResistanceOhm
        self.relativeTotalCapDelta = Self.relativeDelta(delta: totalCapF, baseline: baseline.totalCapF)
        self.relativeResistanceDelta = Self.relativeDelta(delta: resistanceOhm, baseline: baseline.totalResistanceOhm)
    }

    private static func relativeDelta(delta: Double, baseline: Double) -> Double? {
        guard baseline > 0 else {
            return nil
        }
        return delta / baseline
    }
}
