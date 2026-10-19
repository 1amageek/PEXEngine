struct NativeRoutedPEXPreparationBudget {
    private let limits: NativeRoutedPEXPreparationLimits
    private var records = 0
    private var stringBytes = 0
    private var workVisits = 0

    var remainingRecords: Int { limits.maximumRecords - records }
    var remainingStringBytes: Int { limits.maximumStringBytes - stringBytes }
    var remainingWorkVisits: Int { limits.maximumWorkVisits - workVisits }

    init(limits: NativeRoutedPEXPreparationLimits) { self.limits = limits }

    mutating func visit(_ count: Int = 1, isCancelled: () -> Bool = { Task.isCancelled }) throws(NativeRoutedPEXPreparationError) {
        guard !isCancelled(), !Task.isCancelled else { throw .cancelled }
        try Self.charge(count, used: &workVisits, maximum: limits.maximumWorkVisits, name: "workVisits")
    }
    mutating func record(_ count: Int = 1) throws(NativeRoutedPEXPreparationError) {
        try Self.charge(count, used: &records, maximum: limits.maximumRecords, name: "records")
    }
    mutating func string(_ value: String) throws(NativeRoutedPEXPreparationError) {
        try reserveStringBytes(value.utf8.count)
    }
    mutating func reserveStringBytes(_ count: Int) throws(NativeRoutedPEXPreparationError) {
        try Self.charge(count, used: &stringBytes, maximum: limits.maximumStringBytes, name: "stringBytes")
    }
    mutating func reserveGeneratedName(prefix: String, ordinal: Int) throws(NativeRoutedPEXPreparationError) {
        guard ordinal >= 0 else { throw .arithmeticOverflow }
        var digits = 1, remaining = ordinal
        while remaining >= 10 { remaining /= 10; digits += 1 }
        let (count, overflow) = prefix.utf8.count.addingReportingOverflow(digits)
        guard !overflow else { throw .arithmeticOverflow }
        try reserveStringBytes(count)
    }
    private static func charge(_ count: Int, used: inout Int, maximum: Int, name: String) throws(NativeRoutedPEXPreparationError) {
        guard count >= 0, used <= maximum, count <= maximum - used else { throw .limitExceeded(name) }
        used += count
    }
}
