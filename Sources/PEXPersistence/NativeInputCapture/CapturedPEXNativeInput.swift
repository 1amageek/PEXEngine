import Foundation
import PEXCore

/// One manifest-association owner for initial capture and request reload.
struct CapturedPEXNativeInput {
    static func resolve(_ input: PEXNativeInputReference, records: [PEXArtifactRecord],
                        validatedURL: (PEXArtifactRecord) throws -> URL) throws -> PEXNativeInputReference {
        func exactRecord(kind: PEXArtifactKind, id: String) throws -> PEXArtifactRecord {
            let matches = records.filter { $0.id.rawValue == id && $0.matches(kind: kind) && $0.availability == .available }
            guard matches.count == 1, let record = matches.first else {
                throw PEXError.persistenceFailed("Expected one captured native input: \(id)")
            }
            return record
        }
        let configuration = try exactRecord(kind: .nativeConfigurationInput, id: "input-native-configuration")
        guard let reference = configuration.reference, reference.byteCount > 0,
              reference.byteCount <= UInt64(input.maximumConfigurationBytes) else {
            throw PEXError.persistenceFailed("Captured native configuration exceeds its byte budget")
        }
        let configurationURL = try validatedURL(configuration)
        let calibrations = try input.calibrations.map { source in
            let record = try exactRecord(kind: .calibrationInput, id: source.recordID)
            guard record.reference?.id == source.artifactID else {
                throw PEXError.persistenceFailed("Captured calibration identity mismatch: \(source.recordID)")
            }
            return PEXCalibrationInput(artifactID: source.artifactID, url: try validatedURL(record))
        }
        return try input.replacingLocations(configurationURL: configurationURL, calibrations: calibrations)
    }
}
