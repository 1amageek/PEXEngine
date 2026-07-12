public struct ParasiticIRValidator: Sendable {
    public init() {}

    public func validate(_ ir: ParasiticIR) -> ParasiticIRValidationResult {
        var errors: [ParasiticIRValidationError] = []
        var warnings: [ParasiticIRValidationWarning] = []

        var knownNodeRefs: Set<NodeRef> = []
        var nodeNameOwners: [String: Set<String>] = [:]
        var seenNetNames: Set<NetName> = []
        for net in ir.nets {
            if !seenNetNames.insert(net.name).inserted {
                errors.append(.duplicateNetName(net.name.value))
            }
            if net.nodes.isEmpty {
                warnings.append(.emptyNet(netName: net.name.value))
            }
            validateNetValue(net.totalGroundCapF, netName: net.name, metric: "totalGroundCapF", errors: &errors)
            validateNetValue(net.totalCouplingCapF, netName: net.name, metric: "totalCouplingCapF", errors: &errors)
            validateNetValue(net.totalResistanceOhm, netName: net.name, metric: "totalResistanceOhm", errors: &errors)
            var seenNodeNames: Set<NodeName> = []
            for node in net.nodes {
                if !seenNodeNames.insert(node.name).inserted {
                    errors.append(.duplicateNode(netName: net.name.value, nodeName: node.name.value))
                }
                if let coordinate = node.coordinate,
                   !coordinate.x.isFinite || !coordinate.y.isFinite {
                    errors.append(.invalidCoordinate(
                        nodeName: node.name.value,
                        x: coordinate.x,
                        y: coordinate.y
                    ))
                }
                knownNodeRefs.insert(NodeRef(netName: net.name, nodeName: node.name))
                nodeNameOwners[node.name.value, default: []].insert(net.name.value)
            }
        }

        // Check elements
        var seenElementIDs: Set<String> = []
        for element in ir.elements {
            if element.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyElementID)
            }
            // Duplicate ID check
            if !seenElementIDs.insert(element.id).inserted {
                errors.append(.duplicateElementID(element.id))
            }

            validateNodeRef(element.nodeA, elementID: element.id, knownNodeRefs: knownNodeRefs, nodeNameOwners: nodeNameOwners, errors: &errors)
            if let nodeB = element.nodeB {
                validateNodeRef(nodeB, elementID: element.id, knownNodeRefs: knownNodeRefs, nodeNameOwners: nodeNameOwners, errors: &errors)
            }

            // Value validity check
            if !element.value.isFinite {
                errors.append(.invalidValue(elementID: element.id, value: element.value, reason: "Value is not finite"))
            } else if element.value < 0 {
                errors.append(.invalidValue(elementID: element.id, value: element.value, reason: "Value is negative"))
            }

            // Endpoint consistency by element kind.
            if (element.kind == .resistor || element.kind == .inductor) && element.nodeB == nil {
                errors.append(.missingEndpoint(elementID: element.id, kind: element.kind))
            }
            if element.kind == .coupling && element.nodeB == nil {
                errors.append(.ambiguousGroundCapacitor(elementID: element.id))
            }
        }

        // Check for disconnected nodes (nodes not referenced by any element)
        var referencedNodes: Set<NodeRef> = []
        for element in ir.elements {
            referencedNodes.insert(element.nodeA)
            if let nodeB = element.nodeB {
                referencedNodes.insert(nodeB)
            }
        }
        for net in ir.nets {
            for node in net.nodes {
                let ref = NodeRef(netName: net.name, nodeName: node.name)
                if !referencedNodes.contains(ref) {
                    warnings.append(.disconnectedNode(nodeName: node.name.value))
                }
            }
        }

        return ParasiticIRValidationResult(errors: errors, warnings: warnings)
    }

    private func validateNetValue(
        _ value: Double,
        netName: NetName,
        metric: String,
        errors: inout [ParasiticIRValidationError]
    ) {
        guard value.isFinite, value >= 0 else {
            errors.append(.invalidNetValue(
                netName: netName.value,
                metric: metric,
                value: value,
                reason: value.isFinite ? "Value is negative" : "Value is not finite"
            ))
            return
        }
    }

    private func validateNodeRef(
        _ ref: NodeRef,
        elementID: String,
        knownNodeRefs: Set<NodeRef>,
        nodeNameOwners: [String: Set<String>],
        errors: inout [ParasiticIRValidationError]
    ) {
        guard !knownNodeRefs.contains(ref) else { return }
        if let owners = nodeNameOwners[ref.nodeName.value],
           let actualNet = owners.sorted().first {
            errors.append(.inconsistentNetMembership(
                node: ref.nodeName.value,
                claimedNet: ref.netName.value,
                actualNet: actualNet
            ))
        } else {
            errors.append(.danglingNodeReference(elementID: elementID, nodeName: ref.nodeName.value))
        }
    }
}
