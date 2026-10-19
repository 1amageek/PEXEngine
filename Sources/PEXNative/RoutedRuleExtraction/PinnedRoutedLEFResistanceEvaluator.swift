/// Exact explicit LEF resistance law; unavailable cut/layer values cannot fall back.
public struct PinnedRoutedLEFResistanceEvaluator: NativeRoutedLEFResistanceEvaluating {
    public init() {}

    public func wire(sheetResistanceOhmsPerSquare: Double, lengthDatabaseUnits: Int64,
                     widthDatabaseUnits: Int64) throws(NativeRoutedRuleError) -> Double {
        guard sheetResistanceOhmsPerSquare.isFinite, sheetResistanceOhmsPerSquare > 0,
              lengthDatabaseUnits > 0, lengthDatabaseUnits <= Int64(UInt32.max),
              widthDatabaseUnits > 0, widthDatabaseUnits <= Int64(UInt32.max) else { throw .invalidQuery }
        let value = sheetResistanceOhmsPerSquare * Double(lengthDatabaseUnits) / Double(widthDatabaseUnits)
        guard value.isFinite, value > 0 else { throw .unrepresentableArithmetic }
        return value
    }

    public func via(cutResistanceOhms: [Double], maximumCuts: Int = 100_000,
                    isCancelled: () -> Bool = { Task.isCancelled }) throws(NativeRoutedRuleError) -> Double {
        guard maximumCuts > 0, !cutResistanceOhms.isEmpty else { throw .invalidQuery }
        guard cutResistanceOhms.count <= maximumCuts else { throw .limitExceeded }
        var sum = 0.0
        for resistance in cutResistanceOhms {
            if isCancelled() { throw .cancelled }
            guard resistance.isFinite, resistance > 0 else { throw .invalidQuery }
            sum += resistance
            guard sum.isFinite else { throw .unrepresentableArithmetic }
        }
        let count = Double(cutResistanceOhms.count)
        // Pinned getViaResistance_b averages explicit cut-layer R, then divides
        // by cut count; this is its declared law, not a parallel unequal-R solve.
        let value = (sum / count) / count
        guard value.isFinite, value > 0 else { throw .unrepresentableArithmetic }
        return value
    }
}
