public enum ParasiticIRValidationWarning: Sendable, Equatable {
    case disconnectedNode(nodeName: String)
    case suspiciousValue(elementID: String, value: Double, reason: String)
    case emptyNet(netName: String)
}
