public enum ParasiticIRValidationError: Error, Sendable, Equatable {
    case danglingNodeReference(elementID: String, nodeName: String)
    case duplicateElementID(String)
    case invalidValue(elementID: String, value: Double, reason: String)
    case inconsistentNetMembership(node: String, claimedNet: String, actualNet: String)
    case ambiguousGroundCapacitor(elementID: String)
}
