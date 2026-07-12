import Foundation
import CryptoKit

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
        let canonicalArtifacts = inputArtifacts
            .sorted { $0.id < $1.id }
            .map { record in
                PEXCanonicalInputArtifact(
                    id: record.id,
                    kind: record.kind,
                    relativePath: record.relativePath.value,
                    sha256: record.sha256,
                    byteCount: record.byteCount,
                    status: record.status
                )
            }
        let snapshot = PEXCanonicalRequestHashInput(
            topCell: request.topCell,
            layoutFormat: request.layoutFormat,
            sourceNetlistFormat: request.sourceNetlistFormat,
            corners: request.corners,
            technology: PEXCanonicalTechnologyInput(input: request.technology),
            technologyByCorner: request.technologyByCorner.mapValues(PEXCanonicalTechnologyInput.init(input:)),
            processProfile: request.processProfile,
            processProfileDeckSHA256: try processProfileDeckSHA256(request.processProfile),
            backendSelection: PEXCanonicalBackendSelection(request.backendSelection),
            options: request.options,
            inputArtifacts: canonicalArtifacts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return compute(from: try encoder.encode(snapshot))
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

        var hashes: [String: String] = [:]
        for (key, path) in paths {
            let url = URL(filePath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw PEXError.persistenceFailed("Process profile deck is not a regular file: \(path)")
            }
            do {
                hashes[key] = SHA256.hash(data: try Data(contentsOf: url))
                    .map { String(format: "%02x", $0) }
                    .joined()
            } catch {
                throw PEXError.persistenceFailed("Failed to fingerprint process profile deck \(path)", underlying: error)
            }
        }
        return hashes
    }
}

private struct PEXCanonicalRequestHashInput: Sendable, Codable, Hashable {
    let topCell: String
    let layoutFormat: LayoutFormat
    let sourceNetlistFormat: NetlistFormat
    let corners: [PEXCorner]
    let technology: PEXCanonicalTechnologyInput
    let technologyByCorner: [String: PEXCanonicalTechnologyInput]
    let processProfile: PEXProcessProfileReference?
    let processProfileDeckSHA256: [String: String]
    let backendSelection: PEXCanonicalBackendSelection
    let options: PEXRunOptions
    let inputArtifacts: [PEXCanonicalInputArtifact]
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

private struct PEXCanonicalInputArtifact: Sendable, Codable, Hashable {
    let id: String
    let kind: PEXArtifactKind
    let relativePath: String
    let sha256: String?
    let byteCount: Int?
    let status: PEXArtifactStatus
}
