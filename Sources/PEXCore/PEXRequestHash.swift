import Foundation
import CryptoKit
import CircuiteFoundation

public struct PEXRequestHash: Sendable, Codable, Hashable, CustomStringConvertible {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var description: String { value }

    public static func compute(from data: Data) -> PEXRequestHash {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return PEXRequestHash(hex)
    }

    public static func compute(
        for request: PEXRunRequest,
        inputArtifacts: [PEXArtifactRecord]
    ) throws -> PEXRequestHash {
        try encode(canonicalInput(for: request, inputArtifacts: inputArtifacts, corners: request.corners))
    }

    /// Compares captured retry meaning while permitting only corner selection and relocation.
    public static func computeRetryIdentity(
        for request: PEXRunRequest,
        inputArtifacts: [PEXArtifactRecord],
        selecting cornerIDs: Set<PEXCornerID>
    ) throws -> PEXRequestHash {
        let corners = request.corners.filter { cornerIDs.contains($0.id) }.sorted { $0.id.value < $1.id.value }
        guard !cornerIDs.isEmpty, corners.count == cornerIDs.count,
              Set(corners.map(\.id)) == cornerIDs else {
            throw PEXError.invalidInput("Retry identity requires exactly one requested value for every selected corner")
        }
        return try encode(PEXCanonicalRetryHashInput(
            request: canonicalInput(for: request, inputArtifacts: inputArtifacts, corners: corners),
            executionInputArtifacts: request.executionInputArtifacts
        ))
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> PEXRequestHash {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return compute(from: try encoder.encode(value))
    }

    private static func canonicalInput(
        for request: PEXRunRequest,
        inputArtifacts: [PEXArtifactRecord],
        corners: [PEXCorner]
    ) throws -> PEXCanonicalRequestHashInput {
        // The recorded request is derived metadata; hashing it would bind identity to capture locations.
        let canonicalArtifacts = try inputArtifacts
            .filter { !$0.matches(kind: .request) }
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map { record in
                guard let reference = record.reference else {
                    throw PEXError.persistenceFailed("Request input is not available: \(record.id)")
                }
                return PEXCanonicalInputArtifact(id: record.id, reference: reference,
                    processProfileInputRole: record.processProfileInputRole)
            }
        return PEXCanonicalRequestHashInput(
            topCell: request.topCell,
            layoutFormat: request.layoutFormat,
            sourceNetlistFormat: request.sourceNetlistFormat,
            corners: corners,
            technology: PEXCanonicalTechnologyInput(input: request.technology),
            technologyByCorner: request.technologyByCorner.mapValues(PEXCanonicalTechnologyInput.init(input:)),
            nativeInput: request.nativeInput.map(PEXCanonicalNativeInput.init),
            processProfile: request.processProfile.map { $0.mapInputPaths { _ in "captured-input" } },
            processProfileDeckSHA256: try processProfileDeckSHA256(request.processProfile),
            backendSelection: PEXCanonicalBackendSelection(request.backendSelection),
            options: request.options,
            inputArtifacts: canonicalArtifacts
        )
    }

    private static func processProfileDeckSHA256(_ profile: PEXProcessProfileReference?) throws -> [String: String] {
        guard let profile else { return [:] }
        var paths: [String: String] = [:]
        if let primaryDeckPath = profile.primaryDeckPath {
            paths["primary"] = primaryDeckPath
        }
        for (cornerID, path) in profile.cornerDeckPaths {
            paths["corner:\(cornerID)"] = path
        }
        for (role, path) in profile.requiredViewPaths {
            paths["view:\(role)"] = path
        }

        var hashes: [String: String] = [:]
        var contentByPath: [String: String] = [:]
        for (key, path) in paths {
            if let digest = contentByPath[path] {
                hashes[key] = digest
                continue
            }
            let url = URL(filePath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw PEXError.persistenceFailed("Process profile deck is not a regular file: \(path)")
            }
            do {
                hashes[key] = SHA256.hash(data: try Data(contentsOf: url))
                    .map { String(format: "%02x", $0) }
                    .joined()
                contentByPath[path] = hashes[key]
            } catch {
                throw PEXError.persistenceFailed("Failed to fingerprint process profile deck \(path)", underlying: error)
            }
        }
        return hashes
    }
}

private struct PEXCanonicalRetryHashInput: Encodable {
    let request: PEXCanonicalRequestHashInput
    let executionInputArtifacts: [ArtifactReference]
}

private struct PEXCanonicalRequestHashInput: Sendable, Codable, Hashable {
    let topCell: String
    let layoutFormat: LayoutFormat
    let sourceNetlistFormat: NetlistFormat
    let corners: [PEXCorner]
    let technology: PEXCanonicalTechnologyInput
    let technologyByCorner: [String: PEXCanonicalTechnologyInput]
    let nativeInput: PEXCanonicalNativeInput?
    let processProfile: PEXProcessProfileReference?
    let processProfileDeckSHA256: [String: String]
    let backendSelection: PEXCanonicalBackendSelection
    let options: PEXRunOptions
    let inputArtifacts: [PEXCanonicalInputArtifact]
}

private struct PEXCanonicalInputArtifact: Sendable, Codable, Hashable {
    let id: PEXArtifactRecordID
    let reference: ArtifactReference
    let processProfileInputRole: PEXProcessProfileInputRole?
}

private struct PEXCanonicalTechnologyInput: Sendable, Codable, Hashable {
    let sourceKind: String
    let processName: String?
    let inlineTechnology: TechnologyIR?

    init(input: TechnologyInput) {
        switch input {
        case .jsonFile:
            self.sourceKind = "jsonFile"
            self.processName = nil
            self.inlineTechnology = nil
        case .inline(let technology):
            self.sourceKind = "inline"
            self.processName = technology.processName
            self.inlineTechnology = technology
        }
    }
}

private struct PEXCanonicalBackendSelection: Sendable, Codable, Hashable {
    let backendID: String
    let executableName: String?
    let environmentOverrides: [String: String]

    init(_ selection: PEXBackendSelection) {
        self.backendID = selection.backendID
        self.executableName = selection.executablePath.map { URL(filePath: $0).lastPathComponent }
        self.environmentOverrides = selection.environmentOverrides
    }
}

private struct PEXCanonicalNativeInput: Sendable, Codable, Hashable {
    let calibrationArtifacts: [ArtifactID]
    let maximumConfigurationBytes: Int
    let maximumCalibrationBytes: Int
    let maximumTotalCalibrationBytes: UInt64
    let maximumCalibrationArtifacts: Int

    init(_ input: PEXNativeInputReference) {
        calibrationArtifacts = input.calibrations.sorted { $0.recordID < $1.recordID }.map(\.artifactID)
        maximumConfigurationBytes = input.maximumConfigurationBytes
        maximumCalibrationBytes = input.maximumCalibrationBytes
        maximumTotalCalibrationBytes = input.maximumTotalCalibrationBytes
        maximumCalibrationArtifacts = input.maximumCalibrationArtifacts
    }
}
