import Foundation
@_exported import CircuiteFoundation

/// Error raised when a PEX artifact cannot be represented at the Foundation
/// evidence boundary without losing integrity information.
public enum PEXFoundationBoundaryError: Error, Sendable, Equatable, LocalizedError {
    case unavailableArtifact(String)
    case missingDigest(String)
    case missingByteCount(String)
    case invalidArtifactIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .unavailableArtifact(let id):
            "PEX artifact is not available: \(id)"
        case .missingDigest(let id):
            "Available PEX artifact has no SHA-256 digest: \(id)"
        case .missingByteCount(let id):
            "Available PEX artifact has no byte count: \(id)"
        case .invalidArtifactIdentifier(let id):
            "Available PEX artifact has an invalid artifact identifier: \(id)"
        }
    }
}

/// Canonical evidence view exposed by PEX at the cross-engine boundary.
public struct PEXFoundationEvidence: Sendable, Hashable, Codable, ArtifactProducing,
    EvidenceProviding, DiagnosticReporting
{
    public let evidence: EvidenceManifest
    public let diagnostics: [DesignDiagnostic]

    public var artifacts: [ArtifactReference] { evidence.artifacts }

    public init(
        result: PEXRunResult,
        provenance: ExecutionProvenance
    ) throws {
        let artifacts = try result.artifacts.artifacts.compactMap(Self.makeArtifactReference)
        self.evidence = EvidenceManifest(
            provenance: provenance,
            artifacts: artifacts
        )
        self.diagnostics = try result.warnings.map(Self.makeDiagnostic)
            + (result.extractorRun?.diagnostics ?? []).map(Self.makeExtractorDiagnostic)
    }

    private static func makeArtifactReference(
        _ record: PEXArtifactRecord
    ) throws -> ArtifactReference? {
        guard record.status == .available else {
            return nil
        }
        guard let sha256 = record.sha256 else {
            throw PEXFoundationBoundaryError.missingDigest(record.id)
        }
        guard let byteCount = record.byteCount, byteCount >= 0 else {
            throw PEXFoundationBoundaryError.missingByteCount(record.id)
        }
        let kind = try ArtifactKind(rawValue: "pex.\(record.kind.rawValue)")
        let format = try ArtifactFormat(rawValue: formatValue(for: record))
        let location = try ArtifactLocation(workspaceRelativePath: record.relativePath.value)
        let digest = try ContentDigest(algorithm: .sha256, hexadecimalValue: sha256)
        let artifactID: ArtifactID
        do {
            artifactID = try ArtifactID(rawValue: record.id)
        } catch {
            throw PEXFoundationBoundaryError.invalidArtifactIdentifier(record.id)
        }
        return ArtifactReference(
            id: artifactID,
            locator: ArtifactLocator(
                location: location,
                role: role(for: record.kind),
                kind: kind,
                format: format
            ),
            digest: digest,
            byteCount: UInt64(byteCount)
        )
    }

    private static func role(for kind: PEXArtifactKind) -> ArtifactRole {
        switch kind {
        case .layoutInput, .netlistInput, .technologyInput,
             .processProfileDeckInput, .request:
            .input
        case .sourceConnectivityReport, .rawOutput, .log, .parasiticIR,
             .spefRoundTrip, .spiceBackannotation, .report:
            .output
        }
    }

    private static func formatValue(for record: PEXArtifactRecord) -> String {
        let extensionValue = record.relativePath.value
            .split(separator: "/")
            .last?
            .split(separator: ".")
            .last
            .map(String.init)
            .map { $0.lowercased() }
        switch extensionValue {
        case "gds", "gdsii":
            return ArtifactFormat.gdsii.rawValue
        case "oas", "oasis":
            return ArtifactFormat.oasis.rawValue
        case "lef":
            return ArtifactFormat.lef.rawValue
        case "def":
            return ArtifactFormat.def.rawValue
        case "spef":
            return ArtifactFormat.spef.rawValue
        case "dspf":
            return ArtifactFormat.dspf.rawValue
        case "sp", "cir", "spice":
            return ArtifactFormat.spice.rawValue
        default:
            break
        }
        switch record.kind {
        case .spefRoundTrip:
            return ArtifactFormat.spef.rawValue
        case .spiceBackannotation, .netlistInput:
            return ArtifactFormat.spice.rawValue
        case .layoutInput:
            return ArtifactFormat.gdsii.rawValue
        default:
            return ArtifactFormat.json.rawValue
        }
    }

    private static func makeDiagnostic(_ warning: PEXWarning) throws -> DesignDiagnostic {
        DesignDiagnostic(
            code: try DiagnosticCode(rawValue: "pex.\(warning.stage.rawValue)"),
            severity: .warning,
            summary: warning.message,
            suggestedActions: []
        )
    }

    private static func makeExtractorDiagnostic(
        _ diagnostic: PEXExtractorDiagnostic
    ) throws -> DesignDiagnostic {
        let severity: DiagnosticSeverity
        switch diagnostic.severity {
        case .info:
            severity = .information
        case .warning:
            severity = .warning
        case .error, .blocked:
            severity = .error
        }
        return DesignDiagnostic(
            code: try DiagnosticCode(rawValue: "pex.\(diagnostic.code)"),
            severity: severity,
            summary: diagnostic.message,
            suggestedActions: diagnostic.suggestedActions.map {
                SuggestedAction(code: "pex.action", summary: $0)
            }
        )
    }
}

extension PEXRunRequest {
    /// Returns the Foundation hierarchy identity for the requested top cell.
    public func designObjectReference() throws -> DesignObjectReference {
        try DesignObjectReference(kind: .cell, identifier: topCell)
    }
}
