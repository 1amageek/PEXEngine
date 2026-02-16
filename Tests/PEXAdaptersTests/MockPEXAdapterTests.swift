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
        // /usr/bin/true は即座に終了する — ハンドラ設定前に終了してもハングしないことを検証
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
}
