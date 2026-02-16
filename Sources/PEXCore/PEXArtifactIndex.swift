import Foundation

public struct PEXArtifactIndex: Sendable, Codable, Hashable {
    public let manifestURL: URL
    public let requestURL: URL
    public let cornerArtifacts: [PEXCornerID: CornerArtifacts]
    public let reportURL: URL?

    public init(
        manifestURL: URL,
        requestURL: URL,
        cornerArtifacts: [PEXCornerID: CornerArtifacts],
        reportURL: URL? = nil
    ) {
        self.manifestURL = manifestURL
        self.requestURL = requestURL
        self.cornerArtifacts = cornerArtifacts
        self.reportURL = reportURL
    }

    public struct CornerArtifacts: Sendable, Codable, Hashable {
        public let rawDirectory: URL
        public let irURL: URL
        public let logURL: URL?

        public init(
            rawDirectory: URL,
            irURL: URL,
            logURL: URL? = nil
        ) {
            self.rawDirectory = rawDirectory
            self.irURL = irURL
            self.logURL = logURL
        }
    }
}
