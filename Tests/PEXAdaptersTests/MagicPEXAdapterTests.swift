import Testing
import Foundation
import Synchronization
import SignoffToolSupport
@testable import PEXCore
@testable import PEXAdapters
@testable import PEXParsers

/// Integration test for the real Magic-driven PEX adapter. It runs an actual
/// `magic` extraction against the installed Sky130 PDK, so it is gated on the
/// toolchain (`MagicToolchain.locate()`) and skipped where Magic + the PDK are
/// absent. This is also the PEX reliability gate (PEX-3): the extracted parasitic
/// capacitance of a known metal1 plate must match the documented Sky130 met1
/// substrate capacitance, not merely be plumbed through.
@Suite("MagicPEXAdapter (real tool, gated)")
struct MagicPEXAdapterTests {

    static let toolchain = MagicToolchain.locate()

    private func options(_ mode: PEXExtractMode = .cOnly) -> PEXRunOptions {
        PEXRunOptions(
            extractMode: mode,
            includeCouplingCaps: true,
            minCapacitanceF: nil,
            minResistanceOhm: nil,
            maxParallelJobs: 1,
            emitRawArtifacts: true,
            emitIRJSON: false,
            strictValidation: true
        )
    }

    private func minimalTechnology() -> TechnologyIR {
        TechnologyIR(
            processName: "sky130A",
            stack: [],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )
    }

    private func makeDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "MagicPEXAdapterTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutableScript(in directory: URL, name: String, body: String) throws -> URL {
        let scriptURL = directory.appending(path: name)
        try body.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path(percentEncoded: false)
        )
        return scriptURL
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private typealias FakeMagicSuccessFixture = (
        workingDirectory: URL,
        rawOutputDirectory: URL,
        pdkRoot: URL,
        rcFileURL: URL,
        layoutURL: URL,
        sourceNetlistURL: URL,
        executableURL: URL
    )

    private typealias MagicCancellationFixture = (
        workingDirectory: URL,
        rawOutputDirectory: URL,
        childSurvivedURL: URL,
        executableURL: URL
    )

    @Test("MagicToolchain locates a profile-declared Magic requirement")
    func magicToolchainLocatesProfileDeclaredRequirement() throws {
        let root = try makeDir("profile")
        defer { removeTemporaryItem(root) }
        let executableURL = try makeExecutableScript(
            in: root,
            name: "fake-magic",
            body: """
            #!/bin/sh
            exit 0
            """
        )
        let pdkRoot = root.appending(path: "customPDK")
        let magicDirectory = pdkRoot.appending(path: "libs.tech/magic")
        try FileManager.default.createDirectory(at: magicDirectory, withIntermediateDirectories: true)
        let rcFileURL = magicDirectory.appending(path: "custom.magicrc")
        try Data("tech load custom\n".utf8).write(to: rcFileURL)
        let profile = try SignoffPDKProfile(
            profileID: "custom.signoff",
            pdkID: "custom",
            rootDirectoryName: "customPDK",
            candidateRootPaths: [root.path(percentEncoded: false)],
            requirements: [
                SignoffPDKRequiredFile(
                    requirementID: MagicToolchain.magicRequirementID,
                    relativePath: "libs.tech/magic/custom.magicrc"
                ),
            ],
            deckRequirements: [],
            semanticSources: [],
            semanticChecks: []
        )

        let toolchain = try #require(MagicToolchain.locate(
            profile: profile,
            environment: ["MAGIC_BIN": executableURL.path(percentEncoded: false)],
            fileManager: .default
        ))
        #expect(toolchain.magicExecutableURL.path(percentEncoded: false) == executableURL.path(percentEncoded: false))
        #expect(toolchain.pdkRoot == root.path(percentEncoded: false))
        #expect(toolchain.rcFileURL.path(percentEncoded: false) == rcFileURL.path(percentEncoded: false))
        #expect(toolchain.processProfileReference.profileID == "custom.signoff")
        #expect(toolchain.processProfileReference.pdkID == "custom")
        #expect(toolchain.processProfileReference.requirementID == MagicToolchain.magicRequirementID)
        #expect(toolchain.processProfileReference.primaryDeckPath == rcFileURL.path(percentEncoded: false))
    }

    @Test("Magic readiness reports a blocked toolchain without fabricating output")
    func magicReadinessReportsBlockedMissingToolchain() {
        let adapter = MagicPEXAdapter(toolchain: nil)
        let readiness = adapter.toolReadiness(processProfile: nil)

        #expect(readiness.backendID == "magic")
        #expect(readiness.status == .blocked)
        #expect(readiness.diagnostics.contains { $0.code == "extractor_toolchain_missing" })
        #expect(readiness.suggestedActions.contains("run_pex_doctor"))
    }

    @Test(.timeLimit(.minutes(1)))
    func fakeMagicExecutionProducesRawOutputLogAndCanonicalIR() async throws {
        let root = try makeDir("fake-success")
        defer { removeTemporaryItem(root) }
        let fixture = try makeFakeMagicSuccessFixture(in: root)
        let runOptions = options(.rc)
        let context = makeFakeMagicSuccessContext(fixture: fixture, runOptions: runOptions)
        let adapter = MagicPEXAdapter(toolchain: fakeMagicSuccessToolchain(fixture: fixture))

        try await adapter.prepare(context)
        let result = try await adapter.execute(context)

        try assertFakeMagicRawArtifacts(result, context: context, fixture: fixture)
        try assertFakeMagicCanonicalIR(result, context: context, runOptions: runOptions)
    }

    @Test(.timeLimit(.minutes(1)))
    func magicExecutionUsesBackendSelectionExecutableAndEnvironment() async throws {
        let root = try makeDir("selection-override")
        defer { removeTemporaryItem(root) }
        let fixture = try makeFakeMagicSuccessFixture(in: root)
        let failingExecutableURL = try makeExecutableScript(
            in: root,
            name: "fake-magic-pex-should-not-run",
            body: """
            #!/bin/sh
            echo "PEX_ERROR wrong executable"
            exit 99
            """
        )
        let runOptions = options(.rc)
        let context = makeFakeMagicSuccessContext(
            fixture: fixture,
            runOptions: runOptions,
            backendSelection: PEXBackendSelection(
                backendID: "magic",
                executablePath: fixture.executableURL.path(percentEncoded: false),
                environmentOverrides: ["PEX_CUSTOM_SENTINEL": "selected"]
            )
        )
        let adapter = MagicPEXAdapter(toolchain: MagicToolchain(
            magicExecutableURL: failingExecutableURL,
            rcFileURL: fixture.rcFileURL,
            pdkRoot: fixture.pdkRoot.path(percentEncoded: false),
            profileID: "fake.signoff",
            pdkID: "fake"
        ))

        try await adapter.prepare(context)
        let result = try await adapter.execute(context)

        try assertFakeMagicRawArtifacts(result, context: context, fixture: fixture)
    }

    private func makeFakeMagicSuccessFixture(in root: URL) throws -> FakeMagicSuccessFixture {
        let workingDirectory = root.appending(path: "work")
        let rawOutputDirectory = root.appending(path: "raw")
        let pdkRoot = root.appending(path: "pdk")
        try FileManager.default.createDirectory(at: pdkRoot, withIntermediateDirectories: true)
        let rcFileURL = root.appending(path: "fake.magicrc")
        try Data("tech load fake\n".utf8).write(to: rcFileURL)
        let layoutURL = root.appending(path: "inv.gds")
        let sourceNetlistURL = root.appending(path: "inv.spice")
        try Data("fake-gds\n".utf8).write(to: layoutURL)
        try Data("* fake source netlist\n".utf8).write(to: sourceNetlistURL)
        let executableURL = try makeExecutableScript(
            in: root,
            name: "fake-magic-pex-success",
            body: fakeMagicSuccessScriptBody()
        )
        return (
            workingDirectory: workingDirectory,
            rawOutputDirectory: rawOutputDirectory,
            pdkRoot: pdkRoot,
            rcFileURL: rcFileURL,
            layoutURL: layoutURL,
            sourceNetlistURL: sourceNetlistURL,
            executableURL: executableURL
        )
    }

    private func fakeMagicSuccessScriptBody() -> String {
        """
        #!/bin/sh
        if [ "$PEX_CELL" != "inv" ]; then
            echo "PEX_ERROR unexpected cell: $PEX_CELL"
            exit 7
        fi
        if [ "$PEX_EXTRESIST" != "on" ]; then
            echo "PEX_ERROR resistance extraction disabled"
            exit 8
        fi
        if [ -z "$PDK_ROOT" ]; then
            echo "PEX_ERROR pdk root missing"
            exit 9
        fi
        if [ "${PEX_CUSTOM_SENTINEL:-selected}" != "selected" ]; then
            echo "PEX_ERROR selection environment missing"
            exit 10
        fi
        mkdir -p "$(dirname "$PEX_OUT")"
        cat > "$PEX_OUT" <<'SPICE'
        * fake Magic ext2spice
        C0 OUT VSUBS 2f
        C1 OUT IN 1f
        R0 OUT OUT_ext 5
        SPICE
        echo "PEX_DONE fake"
        """
    }

    private func makeFakeMagicSuccessContext(
        fixture: FakeMagicSuccessFixture,
        runOptions: PEXRunOptions,
        backendSelection: PEXBackendSelection = PEXBackendSelection(backendID: "magic")
    ) -> PEXExecutionContext {
        PEXExecutionContext(
            runID: PEXRunID(),
            corner: PEXCorner(id: "tt"),
            layoutURL: fixture.layoutURL,
            sourceNetlistURL: fixture.sourceNetlistURL,
            topCell: "inv",
            technology: minimalTechnology(),
            backendSelection: backendSelection,
            options: runOptions,
            workingDirectory: fixture.workingDirectory,
            rawOutputDirectory: fixture.rawOutputDirectory
        )
    }

    private func fakeMagicSuccessToolchain(fixture: FakeMagicSuccessFixture) -> MagicToolchain {
        MagicToolchain(
            magicExecutableURL: fixture.executableURL,
            rcFileURL: fixture.rcFileURL,
            pdkRoot: fixture.pdkRoot.path(percentEncoded: false),
            profileID: "fake.signoff",
            pdkID: "fake"
        )
    }

    private func assertFakeMagicRawArtifacts(
        _ result: PEXAdapterExecutionResult,
        context: PEXExecutionContext,
        fixture: FakeMagicSuccessFixture
    ) throws {
        let expectedOutputURL = fixture.rawOutputDirectory.appending(path: "tt.spice")
        let expectedLogURL = fixture.rawOutputDirectory.appending(path: "extraction.log")
        #expect(result.rawOutput.format == .spice)
        #expect(result.rawOutput.fileURLs == [expectedOutputURL])
        #expect(result.rawOutput.logURL == expectedLogURL)
        #expect(result.rawOutput.metadata["generator"] == "magic")
        #expect(result.rawOutput.metadata["extresist"] == "on")
        #expect(result.generatedArtifacts.contains { $0.kind == .rawOutput && $0.url == expectedOutputURL })
        #expect(result.generatedArtifacts.contains { $0.kind == .log && $0.url == expectedLogURL })
        #expect(FileManager.default.fileExists(atPath: expectedOutputURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: expectedLogURL.path(percentEncoded: false)))
        let log = try String(contentsOf: expectedLogURL, encoding: .utf8)
        #expect(log.contains("PEX_DONE fake"))
        #expect(result.generatedArtifacts.allSatisfy { $0.cornerID == context.corner.id })
    }

    private func assertFakeMagicCanonicalIR(
        _ result: PEXAdapterExecutionResult,
        context: PEXExecutionContext,
        runOptions: PEXRunOptions
    ) throws {
        let parseContext = PEXParseContext(
            cornerID: context.corner.id,
            runID: context.runID,
            technology: nil,
            options: runOptions
        )
        let ir = try MagicSPICEParasiticParser().parse(result.rawOutput, context: parseContext)
        #expect(ParasiticIRValidator().validate(ir).isValid)
        #expect(ir.nets.contains { abs($0.totalGroundCapF - 2e-15) < 1e-18 })
        #expect(ir.nets.contains { abs($0.totalCouplingCapF - 1e-15) < 1e-18 })
        #expect(ir.nets.contains { abs($0.totalResistanceOhm - 5) < 1e-12 })
        #expect(ir.elements.contains { $0.kind == .capacitor })
        #expect(ir.elements.contains { $0.kind == .coupling })
        #expect(ir.elements.contains { $0.kind == .resistor })
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationCheckTerminatesMagicPEXProcessTree() async throws {
        let root = try makeDir("cancel")
        defer { removeTemporaryItem(root) }
        let fixture = try makeMagicCancellationFixture(in: root)
        let probe = MagicPEXCancellationProbe()
        let context = makeMagicCancellationContext(fixture: fixture, probe: probe)
        let adapter = makeMagicCancellationAdapter(executableURL: fixture.executableURL)

        try await adapter.prepare(context)
        let task = Task {
            try await adapter.execute(context)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        probe.cancel()

        await assertMagicCancellationFailure(task)
        try await assertMagicCancellationKilledChildProcess(fixture.childSurvivedURL)
    }

    private func makeMagicCancellationFixture(in root: URL) throws -> MagicCancellationFixture {
        let workingDirectory = root.appending(path: "work")
        let rawOutputDirectory = root.appending(path: "raw")
        let childSurvivedURL = root.appending(path: "child-survived")
        let executableURL = try makeExecutableScript(
            in: root,
            name: "fake-magic-pex-cancel",
            body: """
            #!/bin/sh
            trap '' TERM
            (
                trap '' TERM
                sleep 1
                touch \(shellSingleQuoted(childSurvivedURL.path(percentEncoded: false)))
            ) &
            echo "PEX_STARTED"
            sleep 10
            """
        )
        return (
            workingDirectory: workingDirectory,
            rawOutputDirectory: rawOutputDirectory,
            childSurvivedURL: childSurvivedURL,
            executableURL: executableURL
        )
    }

    private func makeMagicCancellationContext(
        fixture: MagicCancellationFixture,
        probe: MagicPEXCancellationProbe
    ) -> PEXExecutionContext {
        PEXExecutionContext(
            runID: PEXRunID(),
            corner: PEXCorner(id: "tt"),
            layoutURL: URL(filePath: "/tmp/inverter.gds"),
            sourceNetlistURL: URL(filePath: "/tmp/inverter.spice"),
            topCell: "inv",
            technology: minimalTechnology(),
            options: options(),
            workingDirectory: fixture.workingDirectory,
            rawOutputDirectory: fixture.rawOutputDirectory,
            cancellationCheck: {
                probe.isCancelled
            }
        )
    }

    private func makeMagicCancellationAdapter(executableURL: URL) -> MagicPEXAdapter {
        MagicPEXAdapter(toolchain: MagicToolchain(
            magicExecutableURL: executableURL,
            rcFileURL: URL(filePath: "/tmp/sky130A.magicrc"),
            pdkRoot: "/tmp/pdk"
        ), runner: ProcessRunner(
            timeoutSeconds: 5,
            terminationGraceSeconds: 0.05,
            pipeDrainGraceSeconds: 0.05
        ))
    }

    private func assertMagicCancellationFailure(_ task: Task<PEXAdapterExecutionResult, any Error>) async {
        do {
            _ = try await task.value
            Issue.record("Expected Magic PEX cancellation")
        } catch let error as PEXError {
            #expect(error.kind == .cancelled)
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
    }

    private func assertMagicCancellationKilledChildProcess(_ childSurvivedURL: URL) async throws {
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let didChildSurvive = FileManager.default.fileExists(atPath: childSurvivedURL.path(percentEncoded: false))
        if didChildSurvive {
            Issue.record("Magic PEX child process survived cancellation")
        }
    }

    @Test(
        "Extracts the plate ground cap matching the Sky130 met1 physical value",
        .enabled(if: MagicPEXAdapterTests.toolchain != nil),
        .timeLimit(.minutes(2))
    )
    func extractsPhysicallyCorrectPlateCapacitance() async throws {
        let gds = try #require(
            Bundle.module.url(forResource: "pex_plate", withExtension: "gds"),
            "missing fixture pex_plate.gds"
        )
        let working = try makeDir("work")
        let rawOut = try makeDir("raw")
        defer {
            removeTemporaryItem(working)
            removeTemporaryItem(rawOut)
        }

        let context = PEXExecutionContext(
            runID: PEXRunID(),
            corner: PEXCorner(id: "tt"),
            layoutURL: gds,
            sourceNetlistURL: gds,
            topCell: "pex_plate",
            technology: minimalTechnology(),
            options: options(),
            workingDirectory: working,
            rawOutputDirectory: rawOut
        )

        let adapter = MagicPEXAdapter()
        try await adapter.prepare(context)
        let result = try await adapter.execute(context)
        #expect(result.rawOutput.format == .spice)
        #expect(result.rawOutput.logURL?.lastPathComponent == "extraction.log")
        #expect(result.generatedArtifacts.contains { $0.kind == .log })

        let parseContext = PEXParseContext(
            cornerID: context.corner.id, runID: context.runID, technology: nil, options: options()
        )
        let ir = try MagicSPICEParasiticParser().parse(result.rawOutput, context: parseContext)
        #expect(ParasiticIRValidator().validate(ir).isValid)

        // A 10x10 um met1 plate over substrate: Sky130 met1 areacap (~25.8 aF/um^2)
        // x 100 um^2 + perimcap (~40.6 aF/um) x 40 um ~= 4.20 fF.
        let totalGroundCap = ir.nets.map(\.totalGroundCapF).reduce(0, +)
        #expect(
            abs(totalGroundCap - 4.2008e-15) < 0.2e-15,
            "extracted \(totalGroundCap * 1e15) fF, expected ~4.20 fF (Sky130 met1)"
        )
    }
}

private func removeTemporaryItem(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
    }
}

private final class MagicPEXCancellationProbe: Sendable {
    private let state = Mutex(false)

    var isCancelled: Bool {
        state.withLock { $0 }
    }

    func cancel() {
        state.withLock { $0 = true }
    }
}
