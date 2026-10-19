import PEXCore

public enum NativeRoutedPEXError: Error, Sendable, Equatable {
    public enum Resource: String, Sendable, Equatable { case inputRecords, stringBytes, sourceRecords, workVisits, trackEntries, coordinateValues, graphNodes, graphElements, queryReceipts }
    public enum InvalidReason: String, Sendable, Equatable {
        case sourceIdentity, sourceRange, units, layer, net, node, wire, via, terminal
        case duplicateWire, shortCircuit, nodeAliases, cutContact, nonCenterlineContact
    }
    case invalidInput(reason: InvalidReason, sourceIDs: [String])
    case sourceModel(NativeRoutedRuleError)
    case rule(context: PEXOpenRCXSourceModel.Context, cause: NativeRoutedRuleError, sourceIDs: [String])
    case disconnectedNet(NetName)
    case limitExceeded(Resource)
    case cancelled
    case unrepresentableArithmetic
    case unsupportedNumericalLaw(reason: String)
    case conductor(NativeConductorError)
    case sheetResistance(NativeSheetResistanceError)
    case groundCapacitance(NativeGroundCapacitanceError)
}
