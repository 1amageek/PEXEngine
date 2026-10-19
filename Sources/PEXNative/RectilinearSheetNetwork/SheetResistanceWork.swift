struct SheetResistanceWork {
    var accounting: any NativeConductorResourceAccounting
    let isCancelled: @Sendable () -> Bool
    mutating func charge(_ resource: NativeConductorResource, _ count: Int = 1) throws(NativeSheetResistanceError) {
        do { try accounting.charge(resource, count: count) }
        catch { throw .conductor(error) }
    }
    mutating func visit(_ count: Int = 1) throws(NativeSheetResistanceError) {
        do { try accounting.visit(count, isCancelled: isCancelled) }
        catch { throw .conductor(error) }
    }
    mutating func identifier(_ value: String) throws(NativeSheetResistanceError) {
        for _ in value.utf8 { try visit(); try charge(.stringBytes) }
        guard !value.isEmpty, !value.allSatisfy(\.isWhitespace) else {
            throw .invalidInput(reason: "An identifier is empty.")
        }
    }
    mutating func sorting(_ count: Int) throws(NativeSheetResistanceError) {
        guard count > 1 else { try visit(); return }
        let levels = Int.bitWidth - count.leadingZeroBitCount
        let (cost, overflow) = count.multipliedReportingOverflow(by: levels * 2)
        guard !overflow else { throw .conductor(.arithmeticOverflow) }
        try visit(cost)
    }
}
