import Foundation
@_exported import CircuiteFoundation

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
        let artifacts = result.artifacts.artifacts.compactMap(\.reference)
        self.evidence = EvidenceManifest(
            provenance: provenance,
            artifacts: artifacts
        )
        self.diagnostics = try result.warnings.map(Self.makeDiagnostic)
            + (result.extractorRun?.diagnostics ?? []).map(Self.makeExtractorDiagnostic)
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
