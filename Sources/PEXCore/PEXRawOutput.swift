import Foundation

public struct PEXRawOutput: Sendable, Codable, Hashable {
    public let format: PEXOutputFormat
    public let fileURLs: [URL]
    public let logURL: URL?
    public let metadata: [String: String]

    public init(
        format: PEXOutputFormat,
        fileURLs: [URL],
        logURL: URL? = nil,
        metadata: [String: String] = [:]
    ) {
        self.format = format
        self.fileURLs = fileURLs
        self.logURL = logURL
        self.metadata = metadata
    }
}
