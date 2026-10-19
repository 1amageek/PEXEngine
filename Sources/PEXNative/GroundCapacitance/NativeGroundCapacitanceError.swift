public enum NativeGroundCapacitanceError: Error, Sendable, Equatable {
    public enum InvalidReason: String, Sendable, Equatable {
        case selection, corner, units, layerCoverage, coefficient, sourceRange, geometry
    }
    public enum Resource: String, Sendable, Equatable {
        case inputRecords, stringBytes, outputRecords, workVisits
    }
    case invalidInput(InvalidReason)
    case limitExceeded(Resource)
    case conductor(NativeConductorError)
    case cancelled
    case unrepresentableArithmetic
}
