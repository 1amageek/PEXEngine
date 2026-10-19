struct NativeSheetResistanceBudget: NativeConductorResourceAccounting {
    let ceilings: [NativeConductorResource: Int]
    var consumed: [NativeConductorResource: Int] = [:]
    init(_ limits: NativeSheetResistanceLimits) throws(NativeSheetResistanceError) {
        guard limits.ceilings.values.allSatisfy({ $0 > 0 }) else { throw .invalidConfiguration }
        ceilings = limits.ceilings
    }
    func remaining(_ resource: NativeConductorResource) -> Int {
        (ceilings[resource] ?? 0) - (consumed[resource] ?? 0)
    }
    mutating func charge(_ resource: NativeConductorResource, count: Int) throws(NativeConductorError) {
        guard count >= 0 else { throw .arithmeticOverflow }
        guard count <= remaining(resource) else { throw .limitExceeded(resource) }
        consumed[resource, default: 0] += count
    }
    mutating func visit(_ count: Int, isCancelled: @Sendable () -> Bool) throws(NativeConductorError) {
        if isCancelled() { throw .cancelled }
        try charge(.workVisits, count: count)
    }
}
