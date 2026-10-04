import Foundation
import CircuiteFoundation

public struct PEXNativeInputReference: Sendable, Codable, Hashable {
    public let configurationURL: URL
    public let calibrations: [PEXCalibrationInput]
    public let maximumConfigurationBytes: Int
    public let maximumCalibrationBytes: Int
    public let maximumTotalCalibrationBytes: UInt64
    public let maximumCalibrationArtifacts: Int

    public init(configurationURL: URL, calibrations: [PEXCalibrationInput],
                maximumConfigurationBytes: Int = 16 * 1024 * 1024,
                maximumCalibrationBytes: Int = 64 * 1024 * 1024,
                maximumTotalCalibrationBytes: UInt64 = 256 * 1024 * 1024,
                maximumCalibrationArtifacts: Int = 1024) throws {
        guard configurationURL.isFileURL, maximumConfigurationBytes > 0,
              maximumCalibrationBytes > 0, maximumTotalCalibrationBytes > 0,
              maximumCalibrationArtifacts > 0, calibrations.count <= maximumCalibrationArtifacts else {
            throw PEXError.invalidInput("Invalid native input location or capture budgets")
        }
        var identities = Set<ArtifactID>()
        var remaining = maximumTotalCalibrationBytes
        for input in calibrations {
            guard input.url.isFileURL, input.artifactID.digest.algorithm == .sha256,
                  input.artifactID.byteCount > 0,
                  input.artifactID.byteCount <= UInt64(maximumCalibrationBytes),
                  input.artifactID.byteCount <= remaining,
                  identities.insert(input.artifactID).inserted else {
                throw PEXError.invalidInput("Invalid, duplicate or over-budget native calibration input")
            }
            remaining -= input.artifactID.byteCount
        }
        self.configurationURL = configurationURL
        self.calibrations = calibrations
        self.maximumConfigurationBytes = maximumConfigurationBytes
        self.maximumCalibrationBytes = maximumCalibrationBytes
        self.maximumTotalCalibrationBytes = maximumTotalCalibrationBytes
        self.maximumCalibrationArtifacts = maximumCalibrationArtifacts
    }

    public func replacingLocations(configurationURL: URL, calibrations: [PEXCalibrationInput]) throws -> Self {
        try Self(configurationURL: configurationURL, calibrations: calibrations,
                 maximumConfigurationBytes: maximumConfigurationBytes,
                 maximumCalibrationBytes: maximumCalibrationBytes,
                 maximumTotalCalibrationBytes: maximumTotalCalibrationBytes,
                 maximumCalibrationArtifacts: maximumCalibrationArtifacts)
    }

    private enum CodingKeys: String, CodingKey {
        case configurationURL, calibrations, maximumConfigurationBytes, maximumCalibrationBytes
        case maximumTotalCalibrationBytes, maximumCalibrationArtifacts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(configurationURL: container.decode(URL.self, forKey: .configurationURL),
                      calibrations: container.decode([PEXCalibrationInput].self, forKey: .calibrations),
                      maximumConfigurationBytes: container.decode(Int.self, forKey: .maximumConfigurationBytes),
                      maximumCalibrationBytes: container.decode(Int.self, forKey: .maximumCalibrationBytes),
                      maximumTotalCalibrationBytes: container.decode(UInt64.self, forKey: .maximumTotalCalibrationBytes),
                      maximumCalibrationArtifacts: container.decode(Int.self, forKey: .maximumCalibrationArtifacts))
    }
}
