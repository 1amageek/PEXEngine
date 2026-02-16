import Foundation
import PEXCore

public struct MockPEXAdapter: PEXAdapter {
    public let backendID = "mock"
    public let capabilities = PEXBackendCapabilities(
        supportsCouplingCaps: true,
        supportsCornerSweep: true,
        supportsIncremental: false,
        supportsRCReduction: false,
        nativeOutputFormats: [.spef]
    )

    public init() {}

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

    public func execute(_ context: PEXExecutionContext) async throws -> PEXRawOutput {
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

        return PEXRawOutput(
            format: .spef,
            fileURLs: [outputURL],
            logURL: nil,
            metadata: ["generator": "mock", "version": "1.0"]
        )
    }

    public func cleanup(_ context: PEXExecutionContext) async {
        // No cleanup needed for mock adapter
    }
}
