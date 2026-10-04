struct NativePEXWorkBudget {
    private var remaining: [NativePEXCalculationError.Resource: Int]

    init(_ limits: NativePEXCalculationLimits) throws(NativePEXCalculationError) {
        remaining = [.inputRecords: limits.maximumInputRecords, .coordinateValues: limits.maximumCoordinateValues,
            .meshCells: limits.maximumMeshCells, .networkElements: limits.maximumNetworkElements,
            .workVisits: limits.maximumWorkVisits, .pinContacts: limits.maximumPinContacts]
        guard remaining.values.allSatisfy({ $0 >= 0 }) else { throw .invalidConfiguration }
    }

    mutating func charge(_ resource: NativePEXCalculationError.Resource, _ count: Int = 1) throws(NativePEXCalculationError) {
        guard let available = remaining[resource], count >= 0, count <= available else { throw .limitExceeded(resource) }
        remaining[resource] = available - count
    }

    mutating func visit(_ isCancelled: () -> Bool) throws(NativePEXCalculationError) {
        guard !isCancelled() else { throw .cancelled }
        try charge(.workVisits)
    }
}
