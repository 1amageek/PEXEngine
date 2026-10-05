import PEXCore
import LayoutCore

public enum NativePEXCalculationError: Error, Sendable, Equatable {
    public enum Resource: String, Sendable, Equatable {
        case inputRecords, coordinateValues, meshCells, networkElements, workVisits, pinContacts
    }
    case invalidConfiguration
    case invalidUnits
    case emptyGeometry
    case electricalModel(PEXElectricalModelError)
    case invalidLayerMapping
    case unsupportedSourceLayer(LayoutLayerID)
    case unsupportedSourceVias
    case inconsistentSnapshot
    case ambiguousCutModel
    case unknownViaDefinition(String)
    case unsupportedCutGeometry
    case incompleteCutContact
    case numericFailure
    case cancelled
    case limitExceeded(Resource)
}
