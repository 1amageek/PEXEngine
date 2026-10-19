public protocol NativeRoutedLEFResistanceEvaluating: Sendable {
    func wire(sheetResistanceOhmsPerSquare: Double, lengthDatabaseUnits: Int64,
              widthDatabaseUnits: Int64) throws(NativeRoutedRuleError) -> Double
    func via(cutResistanceOhms: [Double], maximumCuts: Int,
             isCancelled: () -> Bool) throws(NativeRoutedRuleError) -> Double
}
