import Testing
import Foundation
@testable import PEXCore

@Suite("PEXCore Model Tests")
struct PEXCoreModelTests {
    @Test func runIDCreation() {
        let id1 = PEXRunID()
        let id2 = PEXRunID()
        #expect(id1 != id2)
    }

    @Test func cornerIDStringLiteral() {
        let id: PEXCornerID = "tt_25c_1v0"
        #expect(id.value == "tt_25c_1v0")
        #expect(id.description == "tt_25c_1v0")
    }

    @Test func netNameEquality() {
        let a = NetName("VDD")
        let b = NetName("VDD")
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func cornerFromStringID() {
        let corner = PEXCorner(id: "ss_125c_0v81")
        #expect(corner.id.value == "ss_125c_0v81")
        #expect(corner.name == "ss_125c_0v81")
        #expect(corner.temperature == nil)
    }

    @Test func runStatusRawValues() {
        #expect(PEXRunStatus.success.rawValue == "success")
        #expect(PEXRunStatus.partialSuccess.rawValue == "partialSuccess")
        #expect(PEXRunStatus.failed.rawValue == "failed")
    }

    @Test func backendSelectionMock() {
        let sel = PEXBackendSelection.mock()
        #expect(sel.backendID == "mock")
        #expect(sel.executablePath == nil)
    }

    @Test func runOptionsDefault() {
        let opts = PEXRunOptions.default
        #expect(opts.extractMode == .rc)
        #expect(opts.includeCouplingCaps == true)
        #expect(opts.maxParallelJobs == 2)
    }

    @Test func extractionRulesDefault() {
        let rules = ExtractionRules.default
        #expect(rules.reductionPolicy == .none)
        #expect(rules.minCapacitanceF == nil)
    }

    @Test func parasiticUnitsCanonical() {
        let units = ParasiticUnits.canonical
        #expect(units.resistance == .ohm)
        #expect(units.capacitance == .farad)
        #expect(units.coordinate == .micrometer)
    }

    @Test func cornerResultWarningsField() {
        let result = PEXCornerResult(
            cornerID: "tt", status: .success, ir: nil,
            rawOutputURLs: [], logURL: nil,
            warnings: [PEXWarning(stage: .irValidation, cornerID: "tt", message: "test warning")],
            metrics: PEXCornerMetrics(durationSeconds: 0, netCount: 0, elementCount: 0, peakMemoryBytes: nil)
        )
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message == "test warning")
    }

    @Test func errorInternalInvariantViolation() {
        let error = PEXError.internalInvariantViolation("test invariant")
        #expect(error.kind == .internalInvariantViolation)
        #expect(error.stage == .reporting)
        #expect(error.message == "test invariant")
    }

    @Test func artifactRecordUsesRunRelativePathAndHashMetadata() throws {
        let record = PEXArtifactRecord(
            id: "raw-tt",
            kind: .rawOutput,
            stage: .backendExecution,
            cornerID: "tt",
            relativePath: try PEXArtifactPath("raw/tt/tt.spef"),
            sha256: String(repeating: "a", count: 64),
            byteCount: 5,
            status: .available
        )
        #expect(record.relativePath.value == "raw/tt/tt.spef")
        #expect(record.status == .available)
        #expect(record.sha256 != nil)
        #expect(record.byteCount == 5)
    }

    @Test func artifactPathRejectsAbsoluteOrEscapingPaths() {
        do {
            _ = try PEXArtifactPath("/tmp/raw.spef")
            #expect(Bool(false), "Should reject absolute paths")
        } catch {}
        do {
            _ = try PEXArtifactPath("../raw.spef")
            #expect(Bool(false), "Should reject escaping paths")
        } catch {}
    }
}
