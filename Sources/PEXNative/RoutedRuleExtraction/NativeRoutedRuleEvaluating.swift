import PEXCore

public protocol NativeRoutedRuleEvaluating: Sendable {
    func evaluate(context: PEXOpenRCXSourceModel.Context, widthDatabaseUnits: Int64,
                  distance: NativeRoutedRuleDistance, maximumWorkVisits: Int,
                  isCancelled: () -> Bool) throws(NativeRoutedRuleError) -> NativeRoutedRuleEvaluation
}
