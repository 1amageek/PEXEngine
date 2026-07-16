import Synchronization

public final class PEXParserRegistry: Sendable {
    private let parsers: Mutex<[PEXOutputFormat: any PEXParsing]>

    public init() {
        self.parsers = Mutex([:])
    }

    public func register(_ parser: any PEXParsing) {
        parsers.withLock { $0[parser.format] = parser }
    }

    public func parser(for format: PEXOutputFormat) -> (any PEXParsing)? {
        parsers.withLock { $0[format] }
    }

    public var registeredFormats: [PEXOutputFormat] {
        parsers.withLock { Array($0.keys) }
    }
}
