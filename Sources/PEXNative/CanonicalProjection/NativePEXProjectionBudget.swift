struct NativePEXProjectionBudget {
    private var remaining: [NativePEXProjectionError.Resource: Int]
    init(_ limits: NativePEXProjectionLimits) throws(NativePEXProjectionError) {
        remaining = [.inputRecords: limits.maximumInputRecords, .nodes: limits.maximumNodes,
                     .elements: limits.maximumElements, .workVisits: limits.maximumWorkVisits]
        guard remaining.values.allSatisfy({ $0 >= 0 }) else { throw .invalidConfiguration }
    }
    mutating func charge(_ resource: NativePEXProjectionError.Resource, _ count: Int = 1) throws(NativePEXProjectionError) {
        guard let available = remaining[resource], count >= 0, count <= available else { throw .limitExceeded(resource) }
        remaining[resource] = available - count
    }
    mutating func visit(_ isCancelled: () -> Bool) throws(NativePEXProjectionError) {
        guard !isCancelled() else { throw .cancelled }
        try charge(.workVisits)
    }
    mutating func identifier(_ value: String, _ isCancelled: () -> Bool) throws(NativePEXProjectionError) {
        for _ in value.utf8 {
            try visit(isCancelled)
            try charge(.inputRecords)
        }
        guard !value.isEmpty, !value.allSatisfy(\.isWhitespace) else { throw .invalidIdentifier }
    }
}
