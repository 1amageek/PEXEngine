public enum NativePEXElectrodeError: Error, Sendable, Equatable {
    public enum Resource: String, Sendable, Equatable { case inputRecords, faceRecords, contacts, workVisits }
    case invalidConfiguration
    case invalidNetwork
    case invalidBinding(pinIndex: Int)
    case duplicateTerminal
    case missingBinding(pinIndex: Int)
    case ambiguousPinContact(pinIndex: Int, componentIndices: [Int])
    case invalidFace(pinIndex: Int, faceIndex: Int)
    case uncoveredFace(pinIndex: Int, faceIndex: Int)
    case overlappingElectrodes(firstPinIndex: Int, secondPinIndex: Int)
    case numericFailure
    case cancelled
    case limitExceeded(Resource)
}
