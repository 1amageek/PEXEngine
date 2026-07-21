import Foundation
import Testing
import PEXTestSupport
@testable import PEXCLICore
@testable import PEXCore
@testable import PEXEngine

@Suite("PEXCLI output formatter tests")
struct PEXCLIOutputFormatterTests {
    @Test func outputFormatterSuccess() throws {
        let result = try makeCLIResult(
            runID: PEXRunID(),
            requestHash: PEXRequestHash("h"),
            status: .success,
            startedAt: Date(),
            finishedAt: Date(),
            cornerResults: [
                PEXCornerResult(
                    cornerID: "tt", status: .success,
                    ir: ParasiticIR(version: "1.0", cornerID: "tt", units: .canonical, nets: [], elements: [], metadata: [:]),
                    metrics: PEXCornerMetrics(durationSeconds: 0.5, netCount: 3, elementCount: 10)
                )
            ],
            warnings: [PEXWarning(stage: .irValidation, cornerID: "tt", message: "test warn")],
            metrics: PEXRunMetrics(totalDurationSeconds: 0.5, cornerCount: 1, successCount: 1, failureCount: 0)
        )

        let formatter = CLIOutputFormatter()
        let output = formatter.formatResult(result)
        #expect(output.contains("PEX Extraction Complete"))
        #expect(output.contains("success"))
        #expect(output.contains("[OK]"))
        #expect(output.contains("3 nets"))
        #expect(output.contains("10 elements"))
        #expect(output.contains("Warnings"))
        #expect(output.contains("test warn"))
    }

    @Test func outputFormatterPartialSuccess() throws {
        let result = try makeCLIResult(
            runID: PEXRunID(),
            requestHash: PEXRequestHash("h"),
            status: .partialSuccess,
            startedAt: Date(),
            finishedAt: Date(),
            cornerResults: [
                PEXCornerResult(
                    cornerID: "tt", status: .success,
                    ir: ParasiticIR(version: "1.0", cornerID: "tt", units: .canonical, nets: [], elements: [], metadata: [:]),
                    metrics: PEXCornerMetrics(durationSeconds: 0.3, netCount: 2, elementCount: 5)
                ),
                PEXCornerResult(
                    cornerID: "ss", status: .failed,
                    ir: nil,
                    metrics: PEXCornerMetrics(durationSeconds: 0.1, netCount: 0, elementCount: 0)
                ),
            ],
            warnings: [],
            metrics: PEXRunMetrics(totalDurationSeconds: 0.4, cornerCount: 2, successCount: 1, failureCount: 1)
        )

        let formatter = CLIOutputFormatter()
        let output = formatter.formatResult(result)
        #expect(output.contains("[OK]"))
        #expect(output.contains("[FAIL]"))
        #expect(output.contains("1 succeeded"))
        #expect(output.contains("1 failed"))
        #expect(!output.contains("Warnings"))
    }

    @Test func outputFormatterFailed() throws {
        let result = try makeCLIResult(
            runID: PEXRunID(),
            requestHash: PEXRequestHash("h"),
            status: .failed,
            startedAt: Date(),
            finishedAt: Date(),
            cornerResults: [
                PEXCornerResult(
                    cornerID: "tt", status: .failed,
                    ir: nil,
                    metrics: PEXCornerMetrics(durationSeconds: 0.1, netCount: 0, elementCount: 0)
                ),
            ],
            warnings: [],
            metrics: PEXRunMetrics(totalDurationSeconds: 0.1, cornerCount: 1, successCount: 0, failureCount: 1)
        )

        let formatter = CLIOutputFormatter()
        let output = formatter.formatResult(result)
        #expect(output.contains("failed"))
        #expect(output.contains("[FAIL]"))
        #expect(output.contains("0 succeeded"))
    }

    @Test func formatEngineeringValues() throws {
        let cmd = try SummarizeCommand(arguments: ["--run", "/tmp/r"])

        #expect(cmd.formatEngineering(0) == "0")
        #expect(cmd.formatEngineering(1.234e9) == "1.234G")
        #expect(cmd.formatEngineering(5.678e6) == "5.678M")
        #expect(cmd.formatEngineering(2.5e3) == "2.500k")
        #expect(cmd.formatEngineering(100.0) == "100.000")
        #expect(cmd.formatEngineering(1.5e-3) == "1.500m")
        #expect(cmd.formatEngineering(4.7e-6) == "4.700u")
        #expect(cmd.formatEngineering(3.3e-9) == "3.300n")
        #expect(cmd.formatEngineering(1.0e-12) == "1.000p")
        #expect(cmd.formatEngineering(2.5e-15) == "2.500f")

        let subFemto = cmd.formatEngineering(1e-18)
        #expect(subFemto.contains("e"))

        #expect(cmd.formatEngineering(-5e-12) == "-5.000p")
        #expect(cmd.formatEngineering(-1.0e-15) == "-1.000f")
    }

    private func makeCLIResult(
        runID: PEXRunID,
        requestHash: PEXRequestHash,
        status: PEXRunStatus,
        startedAt: Date,
        finishedAt: Date,
        cornerResults: [PEXCornerResult],
        warnings: [PEXWarning],
        metrics: PEXRunMetrics
    ) throws -> PEXRunResult {
        let cornerEntries = cornerResults.map { result in
            PEXArtifactCorner(
                cornerID: result.cornerID,
                status: result.status,
                artifactIDs: []
            )
        }
        let manifest = PEXArtifactManifest(
            runID: runID,
            requestHash: requestHash,
            backendID: "mock",
            status: status,
            startedAt: startedAt,
            finishedAt: finishedAt,
            corners: cornerEntries,
            artifacts: [],
            warnings: warnings,
            provenance: try PEXTestExecutionIdentity.provenance(
                startedAt: startedAt,
                finishedAt: finishedAt
            )
        )
        return try PEXRunResult(
            runID: runID,
            requestHash: requestHash,
            status: status,
            startedAt: startedAt,
            finishedAt: finishedAt,
            cornerResults: cornerResults,
            warnings: warnings,
            artifactManifest: manifest,
            manifestURL: URL(filePath: "/tmp/m.json"),
            metrics: metrics
        )
    }
}
