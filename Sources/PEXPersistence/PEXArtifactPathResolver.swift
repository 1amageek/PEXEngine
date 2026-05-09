import Foundation
import PEXCore

public struct PEXArtifactPathResolver: Sendable {
    public let runDirectory: URL

    public init(runDirectory: URL) {
        self.runDirectory = runDirectory
    }

    public func manifestPath(for url: URL) -> String {
        let runPath = normalizedPath(runDirectory)
        let artifactPath = normalizedPath(url)
        let runPrefix = runPath.hasSuffix("/") ? runPath : "\(runPath)/"
        if artifactPath.hasPrefix(runPrefix) {
            return String(artifactPath.dropFirst(runPrefix.count))
        }
        return artifactPath
    }

    public func irURL(fileName: String, cornerID: PEXCornerID) -> URL {
        artifactURL(
            fileName: fileName,
            defaultDirectory: runDirectory.appending(path: "ir"),
            defaultFileName: "\(cornerID.value).json"
        )
    }

    public func rawURL(fileName: String, cornerID: PEXCornerID) -> URL {
        artifactURL(
            fileName: fileName,
            defaultDirectory: runDirectory.appending(path: "raw").appending(path: cornerID.value),
            defaultFileName: fileName
        )
    }

    public func artifactURL(
        fileName: String,
        defaultDirectory: URL,
        defaultFileName: String
    ) -> URL {
        let expanded = NSString(string: fileName).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(filePath: expanded)
        }
        if fileName.contains("/") {
            return runDirectory.appending(path: fileName)
        }
        return defaultDirectory.appending(path: fileName.isEmpty ? defaultFileName : fileName)
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }
}
