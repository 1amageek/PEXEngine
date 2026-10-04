import Foundation

public enum NativePEXProjectionError: Error, Sendable, Equatable {
    public enum Resource: String, Sendable, Equatable { case inputRecords, nodes, elements, workVisits }
    case invalidConfiguration
    case invalidNetwork
    case invalidIdentifier
    case duplicateBinding(occurrenceIndex: Int, netID: UUID)
    case missingBinding(occurrenceIndex: Int, netID: UUID)
    case unknownBinding(occurrenceIndex: Int, netID: UUID)
    case duplicateNetName(String)
    case terminalNetMismatch(pinIndex: Int)
    case numericFailure
    case cancelled
    case limitExceeded(Resource)
}
