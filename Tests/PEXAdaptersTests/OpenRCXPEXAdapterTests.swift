import Foundation
import Testing
import CircuiteFoundation
import SignoffToolSupport

@testable import PEXAdapters
@testable import PEXCore

@Suite("OpenRCX production process boundary")
struct OpenRCXPEXAdapterTests {
    @Test("OpenRCX readiness blocks when the executable is unavailable")
    func readinessBlocksUnavailableExecutable() throws {
        let fixture = try makeFixture(scriptBody: successScript)
        defer { removeOpenRCXFixture(fixture.root) }
        let profile = makeProfile(fixture: fixture)
        let adapter = OpenRCXPEXAdapter(toolchain: nil)

        let readiness = adapter.toolReadiness(processProfile: profile)

        #expect(readiness.status == .blocked)
        #expect(readiness.diagnostics.contains { $0.code == "extractor_toolchain_missing" })
    }

    @Test("OpenRCX toolchain requires a profile-declared library LEF")
    func toolchainRequiresLibraryLEF() throws {
        let fixture = try makeFixture(scriptBody: successScript)
        defer { removeOpenRCXFixture(fixture.root) }
        let profile = PEXProcessProfileReference(
            primaryDeckPath: fixture.rulesURL.path(percentEncoded: false),
            requiredViewPaths: [
                OpenRCXToolchain.technologyLEFRole: fixture.technologyLEFURL.path(percentEncoded: false),
            ]
        )

        #expect(throws: OpenRCXToolchainError.libraryViewsUnavailable) {
            _ = try OpenRCXToolchain.resolve(
                processProfile: profile,
                executableOverride: fixture.executableURL.path(percentEncoded: false)
            )
        }
    }

    @Test("OpenRCX resolves an executable from OPENROAD_BIN with profile-owned views")
    func resolvesExecutableFromEnvironment() throws {
        let fixture = try makeFixture(scriptBody: successScript)
        defer { removeOpenRCXFixture(fixture.root) }

        let toolchain = try OpenRCXToolchain.resolve(
            processProfile: makeProfile(fixture: fixture),
            environment: [
                "OPENROAD_BIN": fixture.executableURL.path(percentEncoded: false),
            ]
        )

        #expect(toolchain.openROADExecutableURL == fixture.executableURL)
        #expect(toolchain.technologyLEFURL == fixture.technologyLEFURL)
        #expect(toolchain.libraryLEFURLs == [fixture.libraryLEFURL])
        #expect(toolchain.extractionRulesURL == fixture.rulesURL)
    }

    @Test("OpenRCX rejects non-DEF layout input")
    func rejectsNonDEFLayout() async throws {
        let fixture = try makeFixture(scriptBody: successScript)
        defer { removeOpenRCXFixture(fixture.root) }
        let context = makeContext(fixture: fixture, layoutFormat: .gds)

        await #expect(throws: PEXError.self) {
            try await OpenRCXPEXAdapter(toolchain: makeToolchain(fixture: fixture)).prepare(context)
        }
    }

    @Test("OpenRCX retains driver, version output, extraction output, and SPEF")
    func successfulExecutionRetainsEvidence() async throws {
        let fixture = try makeFixture(scriptBody: successScript)
        defer { removeOpenRCXFixture(fixture.root) }
        let context = makeContext(fixture: fixture)
        let adapter = OpenRCXPEXAdapter(toolchain: makeToolchain(fixture: fixture))

        try await adapter.prepare(context)
        let result = try await adapter.execute(context)

        #expect(result.rawOutput.format == .spef)
        #expect(result.rawOutput.metadata["generator"] == "openrcx")
        #expect(result.rawOutput.metadata["openROADVersion"]?.contains("2.0") == true)
        #expect(result.rawOutput.metadata["openROADExecutableSHA256"]?.count == 64)
        #expect(result.executionIdentity.producer.identifier == "pex-openrcx")
        #expect(result.executionIdentity.producer.version == "2.0")
        #expect(
            result.executionIdentity.producer.build
                == result.executionIdentity.binaryDigest.hexadecimalValue
        )
        #expect(result.executionIdentity.invocation.executable == fixture.executableURL.path(percentEncoded: false))
        #expect(result.generatedArtifacts.filter { $0.kind == .processDriver }.count == 1)
        #expect(result.generatedArtifacts.filter { $0.kind == .processEvidence }.count == 1)
        #expect(result.generatedArtifacts.filter { $0.kind == .log }.count == 4)
        #expect(result.generatedArtifacts.filter { $0.kind == .rawOutput }.count == 1)
        for artifact in result.generatedArtifacts {
            #expect(FileManager.default.fileExists(atPath: artifact.url.path(percentEncoded: false)))
            #expect(artifact.producer == result.executionIdentity.producer)
        }
    }

    @Test("OpenRCX rejects an executable that differs from the configured identity")
    func rejectsConfiguredIdentityMismatch() async throws {
        let fixture = try makeFixture(scriptBody: successScript)
        defer { removeOpenRCXFixture(fixture.root) }
        let mismatchedProducer = try ProducerIdentity(
            kind: .tool,
            identifier: "pex-openrcx",
            version: "2.0",
            build: String(repeating: "0", count: 64)
        )
        let context = makeContext(
            fixture: fixture,
            expectedProducer: mismatchedProducer
        )
        let adapter = OpenRCXPEXAdapter(toolchain: makeToolchain(fixture: fixture))

        try await adapter.prepare(context)
        await #expect(throws: PEXAdapterExecutionFailure.self) {
            _ = try await adapter.execute(context)
        }
    }

    @Test("OpenRCX rejects a successful process with zero-byte SPEF")
    func rejectsZeroByteOutput() async throws {
        let fixture = try makeFixture(scriptBody: zeroOutputScript)
        defer { removeOpenRCXFixture(fixture.root) }
        let context = makeContext(fixture: fixture)
        let adapter = OpenRCXPEXAdapter(toolchain: makeToolchain(fixture: fixture))

        try await adapter.prepare(context)
        do {
            _ = try await adapter.execute(context)
            Issue.record("Expected zero-byte OpenRCX output to fail")
        } catch let failure as PEXAdapterExecutionFailure {
            #expect(failure.failureKind == .backendExecutionFailed)
            #expect(failure.generatedArtifacts.contains { $0.kind == .processDriver })
            #expect(failure.generatedArtifacts.filter { $0.kind == .log }.count == 4)
        }
    }

    @Test("OpenRCX rejects version output without a semantic version")
    func rejectsInvalidVersionOutput() async throws {
        let fixture = try makeFixture(scriptBody: invalidVersionScript)
        defer { removeOpenRCXFixture(fixture.root) }
        let context = makeContext(fixture: fixture)
        let adapter = OpenRCXPEXAdapter(toolchain: makeToolchain(fixture: fixture))

        try await adapter.prepare(context)
        do {
            _ = try await adapter.execute(context)
            Issue.record("Expected invalid OpenROAD version output to fail")
        } catch let failure as PEXAdapterExecutionFailure {
            #expect(failure.failureKind == .backendExecutionFailed)
            #expect(failure.message.contains("semantic version"))
            #expect(failure.generatedArtifacts.contains { $0.kind == .processDriver })
            #expect(failure.generatedArtifacts.filter { $0.kind == .log }.count == 2)
        }
    }

    @Test("OpenRCX rejects unrelated numeric output from the version command")
    func rejectsMisleadingVersionOutput() async throws {
        let fixture = try makeFixture(scriptBody: misleadingVersionScript)
        defer { removeOpenRCXFixture(fixture.root) }
        let context = makeContext(fixture: fixture)
        let adapter = OpenRCXPEXAdapter(toolchain: makeToolchain(fixture: fixture))

        try await adapter.prepare(context)
        do {
            _ = try await adapter.execute(context)
            Issue.record("Expected an unrelated numeric version line to fail")
        } catch let failure as PEXAdapterExecutionFailure {
            #expect(failure.failureKind == .backendExecutionFailed)
            #expect(failure.message.contains("OpenROAD semantic version banner"))
        }
    }

    @Test("OpenRCX cancellation is typed and retains pre-launch evidence")
    func cancellationIsTyped() async throws {
        let fixture = try makeFixture(scriptBody: successScript)
        defer { removeOpenRCXFixture(fixture.root) }
        let context = makeContext(fixture: fixture, cancellationCheck: { true })
        let adapter = OpenRCXPEXAdapter(toolchain: makeToolchain(fixture: fixture))

        try await adapter.prepare(context)
        do {
            _ = try await adapter.execute(context)
            Issue.record("Expected OpenRCX cancellation")
        } catch let failure as PEXAdapterExecutionFailure {
            #expect(failure.failureKind == .cancelled)
            #expect(failure.generatedArtifacts.contains { $0.kind == .processDriver })
            #expect(failure.generatedArtifacts.filter { $0.kind == .log }.count == 2)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutRetainsProcessOutput() async throws {
        let fixture = try makeFixture(scriptBody: timeoutScript)
        defer { removeOpenRCXFixture(fixture.root) }
        let context = makeContext(fixture: fixture)
        let adapter = OpenRCXPEXAdapter(
            toolchain: makeToolchain(fixture: fixture),
            processRunner: TimedProcessRunner(timeoutSeconds: 0.5)
        )

        try await adapter.prepare(context)
        do {
            _ = try await adapter.execute(context)
            Issue.record("Expected OpenRCX timeout")
        } catch let failure as PEXAdapterExecutionFailure {
            #expect(failure.failureKind == .timedOut)
            #expect(failure.message.contains("timed out"))
            #expect(failure.generatedArtifacts.filter { $0.kind == .log }.count == 4)
        }
    }

    private var successScript: String {
        """
        #!/bin/sh
        if [ "$1" = "-version" ]; then
          echo "OpenROAD 2.0"
          exit 0
        fi
        echo "extracting"
        echo "extractor diagnostic" >&2
        printf '*SPEF "IEEE 1481-1998"\n*DESIGN "top"\n' > "$PEX_OUT"
        """
    }

    private var zeroOutputScript: String {
        """
        #!/bin/sh
        if [ "$1" = "-version" ]; then
          echo "OpenROAD 2.0"
          exit 0
        fi
        : > "$PEX_OUT"
        """
    }

    private var timeoutScript: String {
        """
        #!/bin/sh
        if [ "$1" = "-version" ]; then
          echo "OpenROAD 2.0"
          exit 0
        fi
        echo "started"
        sleep 5
        """
    }

    private var invalidVersionScript: String {
        """
        #!/bin/sh
        if [ "$1" = "-version" ]; then
          echo "OpenROAD development build"
          exit 0
        fi
        exit 99
        """
    }

    private var misleadingVersionScript: String {
        """
        #!/bin/sh
        if [ "$1" = "-version" ]; then
          echo "unknown option; dependency 2.0"
          exit 0
        fi
        exit 99
        """
    }

    private func makeFixture(scriptBody: String) throws -> OpenRCXFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "OpenRCXPEXAdapterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executableURL = root.appending(path: "openroad")
        try Data(scriptBody.utf8).write(to: executableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path(percentEncoded: false)
        )

        func write(_ name: String, _ contents: String) throws -> URL {
            let url = root.appending(path: name)
            try Data(contents.utf8).write(to: url, options: .atomic)
            return url
        }

        return OpenRCXFixture(
            root: root,
            executableURL: executableURL,
            technologyLEFURL: try write("technology.lef", "VERSION 5.8 ;\n"),
            libraryLEFURL: try write("library.lef", "MACRO INV\nEND INV\n"),
            rulesURL: try write("rules.rules", "Extraction Rules\n"),
            layoutURL: try write("routed.def", "VERSION 5.8 ;\nDESIGN top ;\nEND DESIGN\n"),
            sourceNetlistURL: try write("source.spice", ".subckt top\n.ends top\n"),
            rawOutputDirectory: root.appending(path: "raw"),
            workingDirectory: root.appending(path: "work")
        )
    }

    private func makeToolchain(fixture: OpenRCXFixture) -> OpenRCXToolchain {
        OpenRCXToolchain(
            openROADExecutableURL: fixture.executableURL,
            technologyLEFURL: fixture.technologyLEFURL,
            libraryLEFURLs: [fixture.libraryLEFURL],
            extractionRulesURL: fixture.rulesURL
        )
    }

    private func makeProfile(fixture: OpenRCXFixture) -> PEXProcessProfileReference {
        PEXProcessProfileReference(
            profileID: "test.openrcx",
            pdkID: "test-pdk",
            primaryDeckPath: fixture.rulesURL.path(percentEncoded: false),
            requiredViewPaths: [
                OpenRCXToolchain.technologyLEFRole: fixture.technologyLEFURL.path(percentEncoded: false),
                "\(OpenRCXToolchain.libraryLEFRolePrefix)standard-cells": fixture.libraryLEFURL.path(percentEncoded: false),
            ]
        )
    }

    private func makeContext(
        fixture: OpenRCXFixture,
        layoutFormat: LayoutFormat = .def,
        expectedProducer: ProducerIdentity? = nil,
        cancellationCheck: PEXExecutionContext.CancellationCheck? = nil
    ) -> PEXExecutionContext {
        PEXExecutionContext(
            runID: PEXRunID(),
            corner: PEXCorner(id: "tt"),
            layoutURL: fixture.layoutURL,
            layoutFormat: layoutFormat,
            sourceNetlistURL: fixture.sourceNetlistURL,
            topCell: "top",
            technology: TechnologyIR(
                processName: "test",
                stack: [],
                logicalToPhysicalLayerMap: [:],
                vias: [],
                defaultExtractionRules: .default,
                backendHints: [:]
            ),
            processProfile: makeProfile(fixture: fixture),
            backendSelection: PEXBackendSelection(
                backendID: "openrcx",
                expectedProducer: expectedProducer
            ),
            options: .default,
            workingDirectory: fixture.workingDirectory,
            rawOutputDirectory: fixture.rawOutputDirectory,
            cancellationCheck: cancellationCheck
        )
    }
}

private struct OpenRCXFixture {
    let root: URL
    let executableURL: URL
    let technologyLEFURL: URL
    let libraryLEFURL: URL
    let rulesURL: URL
    let layoutURL: URL
    let sourceNetlistURL: URL
    let rawOutputDirectory: URL
    let workingDirectory: URL
}

private func removeOpenRCXFixture(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("Failed to remove OpenRCX test fixture: \(error)")
    }
}
