/// Open distance selects the source fringe row; finite zero selects the first row.
public enum NativeRoutedRuleDistance: Sendable, Equatable {
    case open
    case finite(databaseUnits: Int64)
}
