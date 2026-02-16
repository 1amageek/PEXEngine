import Synchronization

public final class PEXParserRegistry: Sendable {
    private let parsers: Mutex<[PEXOutputFormat: any PEXParserProtocol]>

    public init() {
        self.parsers = Mutex([:])
    }

    public func register(_ parser: any PEXParserProtocol) {
        parsers.withLock { $0[parser.format] = parser }
    }

    public func parser(for format: PEXOutputFormat) -> (any PEXParserProtocol)? {
        parsers.withLock { $0[format] }
    }

    public var registeredFormats: [PEXOutputFormat] {
        parsers.withLock { Array($0.keys) }
    }
}
