public struct SPEFSourceLocation: Sendable, Hashable {
    public let file: String?
    public let line: Int
    public let column: Int

    public init(file: String? = nil, line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }
}
