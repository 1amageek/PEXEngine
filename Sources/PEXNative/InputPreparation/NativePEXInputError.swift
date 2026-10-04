import LayoutVerify

public enum NativePEXInputError: Error, Sendable, Equatable {
    case invalidField(String)
    case metadataLimitExceeded
    case missingCell(String)
    case duplicateCell(String)
    case duplicatePin(cell: String, name: String)
    case coordinateUnitsMismatch
    case capture(LayoutConductorCaptureError)
    case hierarchy(LayoutHierarchyCaptureError)
    case cancelled
}
