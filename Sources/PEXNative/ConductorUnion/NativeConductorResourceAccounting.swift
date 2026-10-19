/// One cumulative numerical ledger; adapters cannot reset it between components.
protocol NativeConductorResourceAccounting {
    mutating func charge(_ resource: NativeConductorResource, count: Int) throws(NativeConductorError)
    func remaining(_ resource: NativeConductorResource) -> Int
    mutating func visit(_ count: Int, isCancelled: @Sendable () -> Bool) throws(NativeConductorError)
}
