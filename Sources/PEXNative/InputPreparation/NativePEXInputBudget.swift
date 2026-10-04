struct NativePEXInputBudget {
    private(set) var remaining: Int
    init(_ maximum: Int) throws(NativePEXInputError) {
        guard maximum >= 0 else { throw .invalidField("maximumMetadataEntries") }
        remaining = maximum
    }
    mutating func charge(_ count: Int) throws(NativePEXInputError) {
        guard count >= 0, count <= remaining else { throw .metadataLimitExceeded }
        remaining -= count
    }
    mutating func identifier(_ value: String, field: String) throws(NativePEXInputError) {
        try charge(value.utf8.count)
        guard !value.isEmpty, !value.utf8.contains(0) else { throw .invalidField(field) }
    }
}
