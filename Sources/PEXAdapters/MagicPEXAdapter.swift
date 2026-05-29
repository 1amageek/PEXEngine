import Foundation
import PEXCore

/// Real parasitic-extraction adapter driven by Magic against a Sky130-class PDK.
///
/// Extracts parasitic capacitance from `context.layoutURL` for `context.topCell`
/// and writes a SPICE netlist (parsed downstream by `MagicSPICEParasiticParser`).
/// Unlike `MockPEXAdapter`, it produces real parasitics from the layout; if the
/// Magic toolchain is unavailable it fails loudly rather than fabricating output.
public struct MagicPEXAdapter: PEXAdapter {

    public let backendID = "magic"
    // supportsCornerSweep is false on purpose: Magic's base `ext2spice` extracts
    // from a single capacitance table (the open Sky130 PDK ships only sky130A.tech,
    // no per-corner cap tech), so a "corner sweep" would emit identical parasitics
    // for every corner. Genuine multi-corner extraction needs per-corner cap data
    // that this tool/PDK does not provide; declaring true here (e.g. via a linear
    // cap scale) would be a silent approximation, so it stays false until real
    // corner tables are available.
    public let capabilities = PEXBackendCapabilities(
        supportsCouplingCaps: true,
        supportsCornerSweep: false,
        supportsIncremental: false,
        supportsRCReduction: false,
        nativeOutputFormats: [.spice]
    )

    private let toolchain: MagicToolchain?
    private let runner: ProcessRunner

    public init(toolchain: MagicToolchain? = MagicToolchain.locate(), runner: ProcessRunner = ProcessRunner()) {
        self.toolchain = toolchain
        self.runner = runner
    }

    public func prepare(_ context: PEXExecutionContext) async throws {
        let fm = FileManager.default
        for dir in [context.rawOutputDirectory, context.workingDirectory] {
            if !fm.fileExists(atPath: dir.path(percentEncoded: false)) {
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                } catch {
                    throw PEXError(
                        kind: .backendExecutionFailed,
                        stage: .adapterPreparation,
                        cornerID: context.corner.id,
                        backendID: backendID,
                        message: "Failed to create directory \(dir.lastPathComponent)",
                        underlyingDescription: String(describing: error)
                    )
                }
            }
        }
    }

    public func execute(_ context: PEXExecutionContext) async throws -> PEXAdapterExecutionResult {
        guard let toolchain else {
            throw PEXError(
                kind: .adapterUnavailable,
                stage: .backendExecution,
                cornerID: context.corner.id,
                backendID: backendID,
                message: "Magic toolchain not found (set MAGIC_BIN / PDK_ROOT, or install Magic + Sky130)",
                underlyingDescription: nil
            )
        }

        let driverURL = context.workingDirectory.appending(path: "pex_extract.tcl")
        do {
            try Data(MagicToolchain.extractionDriver.utf8).write(to: driverURL)
        } catch {
            throw PEXError(
                kind: .backendExecutionFailed,
                stage: .backendExecution,
                cornerID: context.corner.id,
                backendID: backendID,
                message: "Failed to write extraction driver",
                underlyingDescription: String(describing: error)
            )
        }

        let outputURL = context.rawOutputDirectory.appending(path: "\(context.corner.id.value).spice")
        // Always extract every capacitor (cthresh 0). The includeCouplingCaps
        // option is honored when lowering to IR (MagicSPICEParasiticParser drops
        // coupling elements), because Magic's `cthresh infinite` would discard the
        // grounded caps too — yielding zero parasitics instead of "ground only".
        let cthresh = "0"
        // Extract resistance for RC / R-only modes; capacitance-only otherwise.
        let extractResistance = context.options.extractMode == .rc
            || context.options.extractMode == .rOnly
        var environment = ProcessInfo.processInfo.environment
        environment["PDK_ROOT"] = toolchain.pdkRoot
        environment["PEX_GDS"] = context.layoutURL.path(percentEncoded: false)
        environment["PEX_CELL"] = context.topCell
        environment["PEX_OUT"] = outputURL.path(percentEncoded: false)
        environment["PEX_CTHRESH"] = cthresh
        environment["PEX_EXTRESIST"] = extractResistance ? "on" : "off"

        let result: ProcessRunner.ProcessResult
        do {
            result = try await runner.run(
                executableURL: toolchain.magicExecutableURL,
                arguments: [
                    "-dnull", "-noconsole",
                    "-rcfile", toolchain.rcFileURL.path(percentEncoded: false),
                    driverURL.path(percentEncoded: false),
                ],
                environment: environment,
                workingDirectory: context.workingDirectory
            )
        } catch {
            throw PEXError(
                kind: .backendExecutionFailed,
                stage: .backendExecution,
                cornerID: context.corner.id,
                backendID: backendID,
                message: "Magic process failed to run",
                underlyingDescription: String(describing: error)
            )
        }

        let combinedOutput = result.stdout + "\n" + result.stderr
        let fm = FileManager.default
        guard result.exitCode == 0,
              !combinedOutput.contains("PEX_ERROR"),
              fm.fileExists(atPath: outputURL.path(percentEncoded: false)) else {
            throw PEXError(
                kind: .backendExecutionFailed,
                stage: .backendExecution,
                cornerID: context.corner.id,
                backendID: backendID,
                message: "Magic extraction failed (exit \(result.exitCode))",
                underlyingDescription: combinedOutput
            )
        }

        let rawOutput = PEXRawOutput(
            format: .spice,
            fileURLs: [outputURL],
            logURL: nil,
            metadata: [
                "generator": "magic",
                "cthresh": cthresh,
                "extresist": extractResistance ? "on" : "off",
            ]
        )
        return PEXAdapterExecutionResult(
            rawOutput: rawOutput,
            generatedArtifacts: [
                PEXGeneratedArtifact(
                    kind: .rawOutput,
                    stage: .backendExecution,
                    cornerID: context.corner.id,
                    url: outputURL,
                    provenance: PEXArtifactProvenance(note: "magic ext2spice parasitics")
                )
            ]
        )
    }

    public func cleanup(_ context: PEXExecutionContext) async {
        // Magic writes intermediate .ext files into the working directory; leave
        // them for inspection (the working directory is run-scoped).
    }
}
