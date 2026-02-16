public struct ParasiticIRValidator: Sendable {
    public init() {}

    public func validate(_ ir: ParasiticIR) -> ParasiticIRValidationResult {
        var errors: [ParasiticIRValidationError] = []
        var warnings: [ParasiticIRValidationWarning] = []

        // Build node name set from all nets
        var knownNodes: Set<String> = []
        var nodeToNet: [String: String] = [:]
        for net in ir.nets {
            if net.nodes.isEmpty {
                warnings.append(.emptyNet(netName: net.name.value))
            }
            for node in net.nodes {
                knownNodes.insert(node.name.value)
                if let existing = nodeToNet[node.name.value], existing != net.name.value {
                    errors.append(.inconsistentNetMembership(
                        node: node.name.value,
                        claimedNet: net.name.value,
                        actualNet: existing
                    ))
                }
                nodeToNet[node.name.value] = net.name.value
            }
        }

        // Check elements
        var seenElementIDs: Set<String> = []
        for element in ir.elements {
            // Duplicate ID check
            if !seenElementIDs.insert(element.id).inserted {
                errors.append(.duplicateElementID(element.id))
            }

            // Dangling node reference check
            if !knownNodes.contains(element.nodeA.nodeName.value) {
                errors.append(.danglingNodeReference(elementID: element.id, nodeName: element.nodeA.nodeName.value))
            }
            if let nodeB = element.nodeB, !knownNodes.contains(nodeB.nodeName.value) {
                errors.append(.danglingNodeReference(elementID: element.id, nodeName: nodeB.nodeName.value))
            }

            // Value validity check
            if !element.value.isFinite {
                errors.append(.invalidValue(elementID: element.id, value: element.value, reason: "Value is not finite"))
            } else if element.value < 0 {
                errors.append(.invalidValue(elementID: element.id, value: element.value, reason: "Value is negative"))
            }

            // Ground cap consistency: coupling must have nodeB
            if element.kind == .coupling && element.nodeB == nil {
                errors.append(.ambiguousGroundCapacitor(elementID: element.id))
            }
        }

        // Check for disconnected nodes (nodes not referenced by any element)
        var referencedNodes: Set<String> = []
        for element in ir.elements {
            referencedNodes.insert(element.nodeA.nodeName.value)
            if let nodeB = element.nodeB {
                referencedNodes.insert(nodeB.nodeName.value)
            }
        }
        for node in knownNodes where !referencedNodes.contains(node) {
            warnings.append(.disconnectedNode(nodeName: node))
        }

        return ParasiticIRValidationResult(errors: errors, warnings: warnings)
    }
}
