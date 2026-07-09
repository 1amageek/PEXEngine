import Foundation
import PEXEngine

public struct PEXIRSemanticComparator: Sendable {
    public let valueAbsTolerance: Double

    public init(valueAbsTolerance: Double = 1e-21) {
        self.valueAbsTolerance = valueAbsTolerance
    }

    public func compare(baseline: ParasiticIR, candidate: ParasiticIR) -> [PEXIRComparisonViolation] {
        var violations: [PEXIRComparisonViolation] = []
        let baselineByNet = Dictionary(uniqueKeysWithValues: baseline.nets.map { ($0.name.value, $0) })
        let candidateByNet = Dictionary(uniqueKeysWithValues: candidate.nets.map { ($0.name.value, $0) })
        let netNames = Set(baselineByNet.keys).union(candidateByNet.keys).sorted()

        for netName in netNames {
            guard let baselineNet = baselineByNet[netName] else {
                violations.append(PEXIRComparisonViolation(
                    netName: netName,
                    kind: "net_added",
                    observed: nil,
                    limit: nil,
                    message: "Candidate IR contains a net that is absent from the baseline IR."
                ))
                continue
            }
            guard let candidateNet = candidateByNet[netName] else {
                violations.append(PEXIRComparisonViolation(
                    netName: netName,
                    kind: "net_removed",
                    observed: nil,
                    limit: nil,
                    message: "Candidate IR is missing a net that exists in the baseline IR."
                ))
                continue
            }
            appendNetViolations(
                baseline: baselineNet,
                candidate: candidateNet,
                violations: &violations
            )
        }

        appendElementViolations(
            baseline: baseline.elements,
            candidate: candidate.elements,
            violations: &violations
        )
        return violations
    }

    private func appendNetViolations(
        baseline: ParasiticNet,
        candidate: ParasiticNet,
        violations: inout [PEXIRComparisonViolation]
    ) {
        let netName = baseline.name.value
        if Set(baseline.nodes.map(\.name.value)) != Set(candidate.nodes.map(\.name.value)) {
            violations.append(PEXIRComparisonViolation(
                netName: netName,
                kind: "node_set_mismatch",
                observed: Double(candidate.nodes.count),
                limit: Double(baseline.nodes.count),
                message: "Candidate net node set differs from the baseline net node set."
            ))
        }
        appendNodeCoordinateViolations(
            netName: netName,
            baseline: baseline.nodes,
            candidate: candidate.nodes,
            violations: &violations
        )
        appendValueViolation(
            netName: netName,
            kind: "ground_capacitance_mismatch",
            baseline: baseline.totalGroundCapF,
            candidate: candidate.totalGroundCapF,
            violations: &violations
        )
        appendValueViolation(
            netName: netName,
            kind: "coupling_capacitance_mismatch",
            baseline: baseline.totalCouplingCapF,
            candidate: candidate.totalCouplingCapF,
            violations: &violations
        )
        appendValueViolation(
            netName: netName,
            kind: "resistance_mismatch",
            baseline: baseline.totalResistanceOhm,
            candidate: candidate.totalResistanceOhm,
            violations: &violations
        )
    }

    private func appendElementViolations(
        baseline: [ParasiticElement],
        candidate: [ParasiticElement],
        violations: inout [PEXIRComparisonViolation]
    ) {
        let baselineGroups = Dictionary(grouping: baseline, by: elementKey(_:))
        let candidateGroups = Dictionary(grouping: candidate, by: elementKey(_:))
        let keys = Set(baselineGroups.keys).union(candidateGroups.keys).sorted()
        for key in keys {
            let baselineValues = (baselineGroups[key] ?? []).map(\.value).sorted()
            let candidateValues = (candidateGroups[key] ?? []).map(\.value).sorted()
            let netName = key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
            guard baselineValues.count == candidateValues.count else {
                violations.append(PEXIRComparisonViolation(
                    netName: netName,
                    kind: "element_multiplicity_mismatch",
                    observed: Double(candidateValues.count),
                    limit: Double(baselineValues.count),
                    message: "Candidate element multiplicity differs for a semantic element key."
                ))
                continue
            }
            for index in baselineValues.indices {
                appendValueViolation(
                    netName: netName,
                    kind: "element_value_mismatch",
                    baseline: baselineValues[index],
                    candidate: candidateValues[index],
                    violations: &violations
                )
            }
        }
    }

    private func appendNodeCoordinateViolations(
        netName: String,
        baseline: [ParasiticNode],
        candidate: [ParasiticNode],
        violations: inout [PEXIRComparisonViolation]
    ) {
        let baselineByName = Dictionary(uniqueKeysWithValues: baseline.map { ($0.name.value, $0) })
        let candidateByName = Dictionary(uniqueKeysWithValues: candidate.map { ($0.name.value, $0) })
        for nodeName in Set(baselineByName.keys).intersection(candidateByName.keys).sorted() {
            guard let baselineCoordinate = baselineByName[nodeName]?.coordinate,
                  let candidateCoordinate = candidateByName[nodeName]?.coordinate else {
                if baselineByName[nodeName]?.coordinate != candidateByName[nodeName]?.coordinate {
                    violations.append(PEXIRComparisonViolation(
                        netName: netName,
                        kind: "node_coordinate_mismatch",
                        observed: nil,
                        limit: nil,
                        message: "Candidate node coordinate presence differs for node \(nodeName)."
                    ))
                }
                continue
            }
            let deltaX = abs(candidateCoordinate.x - baselineCoordinate.x)
            let deltaY = abs(candidateCoordinate.y - baselineCoordinate.y)
            guard deltaX > valueAbsTolerance || deltaY > valueAbsTolerance else {
                continue
            }
            violations.append(PEXIRComparisonViolation(
                netName: netName,
                kind: "node_coordinate_mismatch",
                observed: max(deltaX, deltaY),
                limit: valueAbsTolerance,
                message: "Candidate node coordinate differs for node \(nodeName)."
            ))
        }
    }

    private func appendValueViolation(
        netName: String,
        kind: String,
        baseline: Double,
        candidate: Double,
        violations: inout [PEXIRComparisonViolation]
    ) {
        let delta = abs(candidate - baseline)
        guard delta > valueAbsTolerance else {
            return
        }
        violations.append(PEXIRComparisonViolation(
            netName: netName,
            kind: kind,
            observed: candidate,
            limit: baseline,
            message: "Candidate value differs from the baseline by \(delta), exceeding tolerance \(valueAbsTolerance)."
        ))
    }

    private func elementKey(_ element: ParasiticElement) -> String {
        let endpoints: String
        if element.kind == .coupling, let nodeB = element.nodeB {
            endpoints = [nodeRefKey(element.nodeA), nodeRefKey(nodeB)].sorted().joined(separator: "<->")
        } else {
            endpoints = [
                nodeRefKey(element.nodeA),
                element.nodeB.map(nodeRefKey(_:)) ?? "GROUND",
            ].joined(separator: "->")
        }
        return [
            element.nodeA.netName.value,
            element.kind.rawValue,
            endpoints,
        ].joined(separator: "|")
    }

    private func nodeRefKey(_ ref: NodeRef) -> String {
        "\(ref.netName.value):\(ref.nodeName.value)"
    }
}
