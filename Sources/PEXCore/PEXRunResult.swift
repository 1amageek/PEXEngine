import Foundation
import CircuiteFoundation

public struct PEXRunResult: Sendable, Codable, Hashable, ArtifactProducing,
    EvidenceProviding, DiagnosticReporting
{
    public let runID: PEXRunID
    public let requestHash: PEXRequestHash
    public let status: PEXRunStatus
    public let startedAt: Date
    public let finishedAt: Date
    public let cornerResults: [PEXCornerResult]
    public let warnings: [PEXWarning]
    public let artifactManifest: PEXArtifactManifest
    public let manifestURL: URL
    public let metrics: PEXRunMetrics
    public let extractorRun: PEXExtractorRunResult?
    public let resumedFromRunID: PEXRunID?
    public let provenance: ExecutionProvenance

    public init(
        runID: PEXRunID,
        requestHash: PEXRequestHash,
        status: PEXRunStatus,
        startedAt: Date,
        finishedAt: Date,
        cornerResults: [PEXCornerResult],
        warnings: [PEXWarning],
        artifactManifest: PEXArtifactManifest,
        manifestURL: URL,
        metrics: PEXRunMetrics,
        extractorRun: PEXExtractorRunResult? = nil,
        resumedFromRunID: PEXRunID? = nil
    ) throws {
        self.runID = runID
        self.requestHash = requestHash
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.cornerResults = cornerResults
        self.warnings = warnings
        self.artifactManifest = artifactManifest
        self.manifestURL = manifestURL
        self.metrics = metrics
        self.extractorRun = extractorRun
        self.resumedFromRunID = resumedFromRunID
        self.provenance = try ExecutionProvenance(
            producer: ProducerIdentity(
                kind: .engine,
                identifier: "pex.\(artifactManifest.backendID)",
                version: String(PEXArtifactManifest.currentVersion)
            ),
            inputs: artifactManifest.artifacts.compactMap { record in
                switch record.stage {
                case .inputValidation, .technologyResolution:
                    return record.reference
                default:
                    return nil
                }
            },
            startedAt: startedAt,
            completedAt: finishedAt
        )
    }

    public var artifacts: [ArtifactReference] {
        artifactManifest.artifacts.compactMap(\.reference)
    }

    public var evidence: EvidenceManifest {
        EvidenceManifest(
            id: runID.value,
            provenance: provenance,
            artifacts: artifacts
        )
    }

    public var diagnostics: [DesignDiagnostic] {
        warnings.map(Self.designDiagnostic)
            + (extractorRun?.diagnostics ?? []).map(Self.designDiagnostic)
    }

    private static func designDiagnostic(_ warning: PEXWarning) -> DesignDiagnostic {
        let code: DiagnosticCode
        do {
            code = try DiagnosticCode(rawValue: "pex.\(warning.stage.rawValue)")
        } catch {
            code = .trusted("pex.warning")
        }
        return DesignDiagnostic(
            code: code,
            severity: .warning,
            summary: warning.message
        )
    }

    private static func designDiagnostic(
        _ diagnostic: PEXExtractorDiagnostic
    ) -> DesignDiagnostic {
        let code: DiagnosticCode
        do {
            code = try DiagnosticCode(rawValue: "pex.\(diagnostic.code)")
        } catch {
            code = .trusted("pex.invalid-diagnostic-code")
        }
        let severity: DiagnosticSeverity
        switch diagnostic.severity {
        case .info: severity = .information
        case .warning: severity = .warning
        case .error, .blocked: severity = .error
        }
        return DesignDiagnostic(
            code: code,
            severity: severity,
            summary: diagnostic.message,
            detail: code.rawValue == "pex.invalid-diagnostic-code"
                ? "Invalid PEX diagnostic code: \(diagnostic.code)"
                : nil,
            suggestedActions: diagnostic.suggestedActions.map {
                SuggestedAction(code: "pex.action", summary: $0)
            }
        )
    }
}
