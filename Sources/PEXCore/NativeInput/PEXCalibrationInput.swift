import Foundation
import CircuiteFoundation

/// Calibration content identity and its explicitly supplied local availability.
public struct PEXCalibrationInput: Sendable, Codable, Hashable {
    public let artifactID: ArtifactID
    public let url: URL

    public init(artifactID: ArtifactID, url: URL) {
        self.artifactID = artifactID
        self.url = url
    }

    public var recordID: String {
        "input-calibration-\(artifactID.digest.hexadecimalValue)-\(artifactID.byteCount)"
    }
}
