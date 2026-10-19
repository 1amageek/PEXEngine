struct NativeRoutedPEXWorkBudget {
    let limits: NativeRoutedPEXLimits
    var workVisitsConsumed = 0
    private var sourceRecords = 0, records = 0, strings = 0, tracks = 0, coordinates = 0, nodes = 0, elements = 0, receipts = 0

    init(_ limits: NativeRoutedPEXLimits) throws(NativeRoutedPEXError) {
        guard [limits.maximumInputRecords, limits.maximumStringBytes, limits.maximumSourceRecords,
               limits.maximumWorkVisits, limits.maximumTrackEntries, limits.maximumCoordinateValues,
               limits.maximumGraphNodes, limits.maximumGraphElements, limits.maximumQueryReceipts].allSatisfy({ $0 > 0 }) else {
            throw .invalidInput(reason: .units, sourceIDs: [])
        }
        self.limits = limits
    }
    var remainingWork: Int { limits.maximumWorkVisits - workVisitsConsumed }
    func remaining(_ resource: NativeRoutedPEXError.Resource) -> Int {
        switch resource {
        case .inputRecords: limits.maximumInputRecords - records
        case .stringBytes: limits.maximumStringBytes - strings
        case .sourceRecords: limits.maximumSourceRecords - sourceRecords
        case .workVisits: remainingWork
        case .trackEntries: limits.maximumTrackEntries - tracks
        case .coordinateValues: limits.maximumCoordinateValues - coordinates
        case .graphNodes: limits.maximumGraphNodes - nodes
        case .graphElements: limits.maximumGraphElements - elements
        case .queryReceipts: limits.maximumQueryReceipts - receipts
        }
    }
    mutating func visit(_ count: Int = 1, _ isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        if isCancelled() { throw .cancelled }
        guard count >= 0, count <= remainingWork else { throw .limitExceeded(.workVisits) }
        workVisitsConsumed += count
    }
    mutating func charge(_ resource: NativeRoutedPEXError.Resource, _ count: Int = 1) throws(NativeRoutedPEXError) {
        guard count >= 0 else { throw .unrepresentableArithmetic }
        func add(_ current: inout Int, _ maximum: Int) throws(NativeRoutedPEXError) {
            guard count <= maximum - current else { throw .limitExceeded(resource) }
            current += count
        }
        switch resource {
        case .inputRecords: try add(&records, limits.maximumInputRecords)
        case .stringBytes: try add(&strings, limits.maximumStringBytes)
        case .trackEntries: try add(&tracks, limits.maximumTrackEntries)
        case .coordinateValues: try add(&coordinates, limits.maximumCoordinateValues)
        case .graphNodes: try add(&nodes, limits.maximumGraphNodes)
        case .graphElements: try add(&elements, limits.maximumGraphElements)
        case .queryReceipts: try add(&receipts, limits.maximumQueryReceipts)
        case .workVisits: try add(&workVisitsConsumed, limits.maximumWorkVisits)
        case .sourceRecords:
            try add(&sourceRecords, limits.maximumSourceRecords)
        }
    }
}
