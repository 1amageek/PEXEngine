public enum PEXOpenRCXSourceError: Error, Sendable, Equatable {
    public enum Resource: String, Sendable, Hashable, Codable {
        case sourceBytes, lineBytes, lines, records, rows, workVisits
    }
    case invalidSelection(String)
    case invalidModel(String)
    case invalidSource(line: Int, reason: String)
    case sourceMismatch
    case modelMismatch
    case limitExceeded(Resource)
    case cancelled
}
