import Testing
import Foundation
import Synchronization
@testable import PEXCore
@testable import PEXAdapters

@Suite("MockPEXAdapter Tests")
struct MockPEXAdapterTests {
    @Test func adapterCapabilities() {
        let adapter = MockPEXAdapter()
        #expect(adapter.backendID == "mock")
        #expect(adapter.capabilities.supportsCouplingCaps == true)
        #expect(adapter.capabilities.supportsCornerSweep == true)
        #expect(adapter.capabilities.nativeOutputFormats.contains(.spef))
    }

    @Test func mockGeneratorProducesSPEF() {
        let generator = MockParasiticGenerator(
            topCell: "TEST",
            corner: PEXCorner(id: "tt_25c_1v0"),
            includeCouplingCaps: true
        )
        let spef = generator.generateSPEF()
        #expect(spef.contains("*SPEF"))
        #expect(spef.contains("*DESIGN \"TEST\""))
        #expect(spef.contains("*D_NET"))
        #expect(spef.contains("*CAP"))
        #expect(spef.contains("*RES"))
    }

    @Test func mockGeneratorProducesValidIR() {
        let generator = MockParasiticGenerator(
            topCell: "TEST",
            corner: PEXCorner(id: "tt"),
            includeCouplingCaps: true
        )
        let ir = generator.generateParasiticIR()
        #expect(!ir.nets.isEmpty)
        #expect(!ir.elements.isEmpty)
        #expect(ir.cornerID.value == "tt")

        let validator = ParasiticIRValidator()
        let result = validator.validate(ir)
        #expect(result.isValid, "Mock-generated IR should be valid")
    }

    // MARK: - ProcessRunner Tests

    @Test(.timeLimit(.minutes(1)))
    func processRunnerEchoStdout() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executableURL: URL(filePath: "/bin/echo"),
            arguments: ["hello", "world"]
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello world")
        #expect(result.stderr.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerNonZeroExitCode() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", "exit 42"]
        )
        #expect(result.exitCode == 42)
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerImmediateExit() async throws {
        // Verifies that a process exiting immediately after handler setup does not hang.
        let runner = ProcessRunner()
        let result = try await runner.run(
            executableURL: URL(filePath: "/usr/bin/true")
        )
        #expect(result.exitCode == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerInvalidExecutableThrows() async {
        let runner = ProcessRunner()
        do {
            _ = try await runner.run(
                executableURL: URL(filePath: "/nonexistent/binary")
            )
            #expect(Bool(false), "Should have thrown")
        } catch let error as PEXError {
            #expect(error.kind == .backendExecutionFailed)
            #expect(error.message.contains("/nonexistent/binary"))
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerTimeoutTerminatesLongRunningProcess() async throws {
        let runner = ProcessRunner(timeoutSeconds: 0.1, terminationGraceSeconds: 0.05)
        do {
            _ = try await runner.run(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", "printf started; sleep 5"]
            )
            Issue.record("Expected timeout")
        } catch let error as PEXError {
            #expect(error.kind == .backendExecutionFailed)
            #expect(error.message.contains("timed out"))
            #expect(error.underlyingDescription?.contains("started") == true)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerRejectsInvalidTimingConfiguration() async throws {
        let runner = ProcessRunner(timeoutSeconds: 0, terminationGraceSeconds: 0.05)
        do {
            _ = try await runner.run(executableURL: URL(filePath: "/usr/bin/true"))
            Issue.record("Expected invalid timing configuration")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("timeoutSeconds"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerDrainsLargeStdoutAndStderr() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PEXProcessRunnerLargeOutput-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeTemporaryRoot(root) }

        let executable = try writeExecutable(
            named: "mock-large-output",
            in: root,
            contents: """
            #!/usr/bin/env perl
            print "O" x 200000;
            print STDERR "E" x 160000;
            exit 0;
            """
        )

        let result = try await ProcessRunner().run(executableURL: executable)

        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 200_000)
        #expect(result.stderr.count == 160_000)
    }

    @Test(.timeLimit(.minutes(1)))
    func processRunnerDoesNotWaitForInheritedPipeEOFAfterParentExit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PEXProcessRunnerPipeInheritance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { removeTemporaryRoot(root) }

        let childFinished = root.appending(path: "child-finished")
        let executable = try writeExecutable(
            named: "mock-parent-exit",
            in: root,
            contents: """
            #!/usr/bin/env perl
            print "parent-exited\\n";
            my $pid = fork();
            if (!defined $pid) {
                exit 2;
            }
            if ($pid == 0) {
                sleep 8;
                open my $fh, ">", "\(childFinished.path(percentEncoded: false))";
                print $fh "done\\n";
                close $fh;
                exit 0;
            }
            exit 0;
            """
        )

        let runner = ProcessRunner(
            timeoutSeconds: 5.0,
            terminationGraceSeconds: 0.05,
            pipeDrainGraceSeconds: 0.05
        )
        let result = try await runner.run(executableURL: executable)

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("parent-exited"))
        #expect(!FileManager.default.fileExists(atPath: childFinished.path(percentEncoded: false)))
    }

    @Test func temperatureScalesValues() {
        let coldCorner = PEXCorner(id: PEXCornerID("cold"), name: "cold", temperature: -40)
        let hotCorner = PEXCorner(id: PEXCornerID("hot"), name: "hot", temperature: 125)

        let coldGen = MockParasiticGenerator(topCell: "T", corner: coldCorner)
        let hotGen = MockParasiticGenerator(topCell: "T", corner: hotCorner)

        let coldIR = coldGen.generateParasiticIR()
        let hotIR = hotGen.generateParasiticIR()

        // Hot corner should have larger parasitic values due to temperature scaling
        let coldTotal = coldIR.elements.reduce(0.0) { $0 + $1.value }
        let hotTotal = hotIR.elements.reduce(0.0) { $0 + $1.value }
        #expect(hotTotal > coldTotal)
    }

    private func removeTemporaryRoot(_ root: URL) {
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            Issue.record("Failed to remove temporary root: \(error)")
        }
    }

    private func writeExecutable(named name: String, in root: URL, contents: String) throws -> URL {
        let url = root.appending(path: name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path(percentEncoded: false)
        )
        return url
    }
}
