public struct ParasiticIRValidator: Sendable {
    public init() {}

    public func validate(_ ir: ParasiticIR) -> ParasiticIRValidationResult {
        var errors: [ParasiticIRValidationError] = []
        var warnings: [ParasiticIRValidationWarning] = []

        var knownNodeRefs: Set<NodeRef> = []
        var nodeNameOwners: [String: Set<String>] = [:]
        for net in ir.nets {
            if net.nodes.isEmpty {
                warnings.append(.emptyNet(netName: net.name.value))
            }
            for node in net.nodes {
                knownNodeRefs.insert(NodeRef(netName: net.name, nodeName: node.name))
                nodeNameOwners[node.name.value, default: []].insert(net.name.value)
            }
        }

        // Check elements
        var seenElementIDs: Set<String> = []
        for element in ir.elements {
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
            if element.kind == .resistor && element.nodeB == nil {
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
