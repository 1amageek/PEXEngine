import Foundation
import LayoutVerify

public enum NativePEXInputError: Error, Sendable, Equatable {
    case invalidField(String)
    case metadataLimitExceeded
    case missingCell(String)
    case duplicateCell(String)
    case duplicatePin(cell: String, name: String)
    case invalidNetOccurrence(Int)
    case netCellMismatch(occurrenceIndex: Int, expected: String, actual: String)
    case missingSourceNet(occurrenceIndex: Int, name: String)
    case ambiguousSourceNet(occurrenceIndex: Int, name: String)
    case undeclaredSupplementalNet(cell: String, netID: UUID)
    case duplicateResolvedNetBinding(occurrenceIndex: Int, netID: UUID)
    case coordinateUnitsMismatch
    case conductiveLayersMismatch
    case capture(LayoutConductorCaptureError)
    case hierarchy(LayoutHierarchyCaptureError)
    case cancelled
}
