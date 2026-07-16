import Foundation
import PEXCore

/// Deterministic extractor used exclusively by PEXEngine tests.

public struct MockPEXAdapter: PEXExtracting, PEXAdapterReadinessProviding {
    public let backendID = "mock"
    public let capabilities = PEXBackendCapabilities(
        supportsCouplingCaps: true,
        supportsCornerSweep: true,
        supportsIncremental: false,
        supportsRCReduction: false,
        nativeOutputFormats: [.spef]
    )

    public init() {}

    public func toolReadiness(processProfile: PEXProcessProfileReference?) -> PEXExtractorToolReadiness {
        PEXExtractorToolReadiness(
            backendID: backendID,
            status: .ready,
            reason: "Synthetic mock adapter is available in process.",
            processProfile: processProfile,
            capabilities: capabilities,
            diagnostics: [
                PEXExtractorDiagnostic(
                    diagnosticID: "mock-adapter:synthetic-output",
                    code: "synthetic_extractor",
                    severity: .info,
                    message: "Mock PEX output is deterministic test material and is not physical signoff evidence.",
                    suggestedActions: ["use_external_extractor_for_physical_signoff"]
                )
            ],
            suggestedActions: ["use_external_extractor_for_physical_signoff"]
        )
    }

    public func supportsCornerSweep(
        corners: [PEXCorner],
        processProfile: PEXProcessProfileReference?
    ) -> Bool {
        capabilities.supportsCornerSweep
    }

    public func prepare(_ context: PEXExecutionContext) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: context.rawOutputDirectory.path(percentEncoded: false)) {
            do {
                try fm.createDirectory(at: context.rawOutputDirectory, withIntermediateDirectories: true)
            } catch {
                throw PEXError(
                    kind: .backendExecutionFailed,
                    stage: .adapterPreparation,
                    cornerID: context.corner.id,
                    backendID: backendID,
                    message: "Failed to create raw output directory",
                    underlyingDescription: String(describing: error)
                )
            }
        }
    }

    public func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        let generator = MockParasiticGenerator(
            topCell: context.topCell,
            corner: context.corner,
            includeCouplingCaps: context.options.includeCouplingCaps
        )
        let spefContent = generator.generateSPEF()

        let outputURL = context.rawOutputDirectory.appending(path: "\(context.corner.id.value).spef")
        let data = Data(spefContent.utf8)
        do {
            try data.write(to: outputURL)
        } catch {
            throw PEXError(
                kind: .backendExecutionFailed,
                stage: .backendExecution,
                cornerID: context.corner.id,
                backendID: backendID,
                message: "Failed to write mock SPEF output",
                underlyingDescription: String(describing: error)
            )
        }

        let rawOutput = PEXRawOutput(
            format: .spef,
            fileURLs: [outputURL],
            logURL: nil,
            metadata: ["generator": "mock", "version": "1.0"]
        )
        return PEXAdapterExecutionResult(
            rawOutput: rawOutput,
            generatedArtifacts: [
                PEXGeneratedArtifact(
                    kind: .rawOutput,
                    stage: .backendExecution,
                    cornerID: context.corner.id,
                    url: outputURL,
                    provenance: PEXArtifactProvenance(note: "mock SPEF output")
                )
            ]
        )
    }

    public func cleanup(_ context: PEXExecutionContext) async {
        // No cleanup needed for mock adapter
    }
}
