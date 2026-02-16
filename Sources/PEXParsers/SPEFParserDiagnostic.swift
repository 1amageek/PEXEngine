public struct SPEFParserDiagnostic: Error, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    public let severity: Severity
    public let message: String
    public let location: SPEFSourceLocation?

    public init(severity: Severity, message: String, location: SPEFSourceLocation? = nil) {
        self.severity = severity
        self.message = message
        self.location = location
    }

    public var description: String {
        if let loc = location {
            return "\(severity.rawValue): \(loc.file ?? "<input>"):\(loc.line):\(loc.column): \(message)"
        }
        return "\(severity.rawValue): \(message)"
    }
}
