struct NativeConductorUnionBudget: NativeConductorResourceAccounting {
    private let ceilings: [NativeConductorResource: Int]
    private var used: [NativeConductorResource: Int] = [:]

    init(_ limits: NativeConductorUnionLimits) throws(NativeConductorError) {
        ceilings = [.inputRecords: limits.maximumInputRecords, .stringBytes: limits.maximumStringBytes,
            .unionBands: limits.maximumUnionBands, .boundarySegments: limits.maximumBoundarySegments,
            .contributorIndices: limits.maximumContributorIndices, .coordinateValues: limits.maximumCoordinateValues,
            .workVisits: limits.maximumWorkVisits]
        guard ceilings.values.allSatisfy({ $0 > 0 }) else {
            throw .invalidInput(reason: "Conductor limits must be positive", sourceIDs: [])
        }
    }
    func remaining(_ resource: NativeConductorResource) -> Int {
        (ceilings[resource] ?? 0) - (used[resource] ?? 0)
    }
    mutating func charge(_ resource: NativeConductorResource, count: Int) throws(NativeConductorError) {
        guard count >= 0 else { throw .arithmeticOverflow }
        guard count <= remaining(resource) else { throw .limitExceeded(resource) }
        used[resource, default: 0] += count
    }
    mutating func visit(_ count: Int, isCancelled: @Sendable () -> Bool) throws(NativeConductorError) {
        if isCancelled() { throw .cancelled }
        try charge(.workVisits, count: count)
    }
}
