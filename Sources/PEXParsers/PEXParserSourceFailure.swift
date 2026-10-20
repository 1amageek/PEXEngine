/// A controlled source failure and the owner of its admitted diagnostic payload.
/// Keep its retention anchor while separately sharing its underlying cause.
public struct PEXParserSourceFailure: Error, Sendable {
    public let cause: any Error
    public let retention: PEXParserRetention

    init(cause: any Error, retention: PEXParserRetention) {
        self.cause = cause
        self.retention = retention
    }
}
