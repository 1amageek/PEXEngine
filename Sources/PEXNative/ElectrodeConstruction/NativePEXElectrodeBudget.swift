struct NativePEXElectrodeBudget {
    private var remaining: [NativePEXElectrodeError.Resource: Int]
    init(_ limits: NativePEXElectrodeLimits) throws(NativePEXElectrodeError) {
        remaining = [.inputRecords: limits.maximumInputRecords, .faceRecords: limits.maximumFaceRecords,
                     .contacts: limits.maximumContacts, .workVisits: limits.maximumWorkVisits]
        guard remaining.values.allSatisfy({ $0 >= 0 }) else { throw .invalidConfiguration }
    }
    mutating func charge(_ resource: NativePEXElectrodeError.Resource, _ count: Int = 1) throws(NativePEXElectrodeError) {
        guard let available = remaining[resource], count >= 0, count <= available else { throw .limitExceeded(resource) }
        remaining[resource] = available - count
    }
    mutating func visit(_ isCancelled: () -> Bool) throws(NativePEXElectrodeError) {
        guard !isCancelled() else { throw .cancelled }
        try charge(.workVisits)
    }
}
