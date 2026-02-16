public enum SPEFToken: Sendable, Hashable {
    case keyword(String)        // *SPEF, *DESIGN, *D_NET, *CONN, *CAP, *RES, *END, etc.
    case number(Double)         // numeric literals
    case identifier(String)     // unquoted names (net names, node names)
    case string(String)         // "quoted strings"
    case mappedName(Int)        // *123 format (name map references)
    case colon                  // :
    case slash                  // /
    case leftBracket            // [
    case rightBracket           // ]
    case newline
    case endOfFile

    public struct Located: Sendable, Hashable {
        public let token: SPEFToken
        public let location: SPEFSourceLocation

        public init(token: SPEFToken, location: SPEFSourceLocation) {
            self.token = token
            self.location = location
        }
    }
}
