/// Value-only bridge. Each lower call returns this exact cumulative ledger.
struct NativeRoutedConductorAccounting: NativeConductorResourceAccounting {
    var budget: NativeRoutedPEXWorkBudget

    static func resource(_ value: NativeConductorResource) -> NativeRoutedPEXError.Resource {
        switch value {
        case .inputRecords, .contributorIndices: .inputRecords
        case .stringBytes: .stringBytes
        case .unionBands, .boundarySegments: .trackEntries
        case .coordinateValues: .coordinateValues
        case .meshCells, .graphNodes: .graphNodes
        case .graphElements: .graphElements
        case .workVisits: .workVisits
        }
    }
    func remaining(_ resource: NativeConductorResource) -> Int { budget.remaining(Self.resource(resource)) }
    mutating func charge(_ resource: NativeConductorResource, count: Int) throws(NativeConductorError) {
        do { try budget.charge(Self.resource(resource), count) }
        catch {
            switch error {
            case .cancelled: throw .cancelled
            case .limitExceeded: throw .limitExceeded(resource)
            default: throw .arithmeticOverflow
            }
        }
    }
    mutating func visit(_ count: Int, isCancelled: @Sendable () -> Bool) throws(NativeConductorError) {
        if isCancelled() { throw .cancelled }
        try charge(.workVisits, count: count)
    }
}
