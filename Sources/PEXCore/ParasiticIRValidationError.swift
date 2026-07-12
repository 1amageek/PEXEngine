public enum ParasiticIRValidationError: Error, Sendable, Equatable {
    case danglingNodeReference(elementID: String, nodeName: String)
    case duplicateElementID(String)
    case duplicateNetName(String)
    case duplicateNode(netName: String, nodeName: String)
    case emptyElementID
    case invalidValue(elementID: String, value: Double, reason: String)
    case invalidNetValue(netName: String, metric: String, value: Double, reason: String)
    case invalidCoordinate(nodeName: String, x: Double, y: Double)
    case inconsistentNetMembership(node: String, claimedNet: String, actualNet: String)
    case ambiguousGroundCapacitor(elementID: String)
    case missingEndpoint(elementID: String, kind: ElementKind)
}
