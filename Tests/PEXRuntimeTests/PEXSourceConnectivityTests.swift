import Foundation
import Testing
@testable import PEXCore
@testable import PEXRuntime
@testable import PEXAdapters
@testable import PEXParsers
@testable import PEXPersistence

@Suite("PEX source connectivity")
struct PEXSourceConnectivityTests {
    @Test func checkerMatchesExtractedPinAliasesAgainstSpiceNodes() throws {
        let directory = temporaryDirectory("connectivity-pass")
        defer { remove(directory) }
        let sourceURL = directory.appending(path: "source.cir")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        .subckt TOP in out vdd
        R1 in n1 1k
        C1 out 0 1p
        XU1 in out vdd cell
        .ends TOP
        """.utf8).write(to: sourceURL)

        let ir = ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: [
                ParasiticNet(
                    name: NetName("in"),
                    nodes: [ParasiticNode(name: NodeName("in"), kind: .pin, instancePath: nil, coordinate: nil)],
                    totalGroundCapF: 0,
                    totalCouplingCapF: 0,
                    totalResistanceOhm: 0
                ),
                ParasiticNet(
                    name: NetName("out"),
                    nodes: [ParasiticNode(name: NodeName("out"), kind: .pin, instancePath: nil, coordinate: nil)],
                    totalGroundCapF: 0,
                    totalCouplingCapF: 0,
                    totalResistanceOhm: 0
                ),
                ParasiticNet(
                    name: NetName("vdd"),
                    nodes: [ParasiticNode(name: NodeName("XU1:vdd"), kind: .pin, instancePath: InstancePath("XU1"), coordinate: nil)],
                    totalGroundCapF: 0,
                    totalCouplingCapF: 0,
                    totalResistanceOhm: 0
                ),
            ],
            elements: [],
            metadata: [:]
        )

        let report = try PEXSourceConnectivityChecker().check(
            sourceNetlistURL: sourceURL,
            sourceNetlistFormat: .spice,
            ir: ir
        )

        #expect(report.status == PEXSourceConnectivityStatus.passed)
        #expect(report.extractedPinNodeCount == 3)
        #expect(report.matchedPinNodeCount == 3)
        #expect(report.unmatchedExtractedPinNodes.isEmpty)
    }

    @Test func checkerReportsUnmatchedExtractedPins() throws {
        let directory = temporaryDirectory("connectivity-fail")
        defer { remove(directory) }
        let sourceURL = directory.appending(path: "source.cir")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("R1 in out 1k\n".utf8).write(to: sourceURL)
        let ir = ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: [
                ParasiticNet(
                    name: NetName("missing"),
                    nodes: [ParasiticNode(name: NodeName("missing"), kind: .pin, instancePath: nil, coordinate: nil)],
                    totalGroundCapF: 0,
                    totalCouplingCapF: 0,
                    totalResistanceOhm: 0
                ),
            ],
            elements: [],
            metadata: [:]
        )

        let report = try PEXSourceConnectivityChecker().check(
            sourceNetlistURL: sourceURL,
            sourceNetlistFormat: .spice,
            ir: ir
        )

        #expect(report.status == PEXSourceConnectivityStatus.failed)
        #expect(report.unmatchedExtractedPinNodes == ["missing"])
        #expect(!report.isSatisfied)
    }

    @Test func checkerJoinsSpiceContinuationLinesForSubcktAndInstances() throws {
        let directory = temporaryDirectory("connectivity-continuation")
        defer { remove(directory) }
        let sourceURL = directory.appending(path: "source.cir")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        .subckt TOP in
        + out vdd
        R1 in
        + out 1k
        XU1 in out
        + vdd cell
        .ends TOP
        """.utf8).write(to: sourceURL)
        let ir = ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: [
                ParasiticNet(name: NetName("in"), nodes: [ParasiticNode(name: NodeName("in"), kind: .pin, instancePath: nil, coordinate: nil)], totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0),
                ParasiticNet(name: NetName("out"), nodes: [ParasiticNode(name: NodeName("out"), kind: .pin, instancePath: nil, coordinate: nil)], totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0),
                ParasiticNet(name: NetName("vdd"), nodes: [ParasiticNode(name: NodeName("vdd"), kind: .pin, instancePath: nil, coordinate: nil)], totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0),
            ],
            elements: [],
            metadata: [:]
        )

        let report = try PEXSourceConnectivityChecker().check(
            sourceNetlistURL: sourceURL,
            sourceNetlistFormat: .spice,
            ir: ir
        )

        #expect(report.status == .passed)
        #expect(report.matchedPinNodeCount == 3)
    }

    @Test func checkerMatchesVerilogModulePortsAndConnections() throws {
        let directory = temporaryDirectory("connectivity-verilog")
        defer { remove(directory) }
        let sourceURL = directory.appending(path: "source.v")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        module TOP(input in, output out, inout vdd);
          wire n1;
          cell u1 (.A(in), .Y(out), .VDD(vdd), .Z(n1));
        endmodule
        """.utf8).write(to: sourceURL)
        let ir = ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: [
                ParasiticNet(name: NetName("in"), nodes: [ParasiticNode(name: NodeName("in"), kind: .pin, instancePath: nil, coordinate: nil)], totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0),
                ParasiticNet(name: NetName("out"), nodes: [ParasiticNode(name: NodeName("out"), kind: .pin, instancePath: nil, coordinate: nil)], totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0),
                ParasiticNet(name: NetName("vdd"), nodes: [ParasiticNode(name: NodeName("u1:vdd"), kind: .pin, instancePath: InstancePath("u1"), coordinate: nil)], totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0),
            ],
            elements: [],
            metadata: [:]
        )

        let report = try PEXSourceConnectivityChecker().check(
            sourceNetlistURL: sourceURL,
            sourceNetlistFormat: .verilog,
            ir: ir
        )

        #expect(report.status == PEXSourceConnectivityStatus.passed)
        #expect(report.isSatisfied)
        #expect(report.extractedPinNodeCount == 3)
        #expect(report.matchedPinNodeCount == 3)
    }

    @Test func checkerWarnsForMalformedVerilogWithoutClaimingAgreement() throws {
        let directory = temporaryDirectory("connectivity-verilog-malformed")
        defer { remove(directory) }
        let sourceURL = directory.appending(path: "source.v")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("module TOP(input in;\n".utf8).write(to: sourceURL)
        let ir = ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: "tt",
            units: .canonical,
            nets: [ParasiticNet(name: NetName("in"), nodes: [ParasiticNode(name: NodeName("in"), kind: .pin, instancePath: nil, coordinate: nil)], totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0)],
            elements: [],
            metadata: [:]
        )

        let report = try PEXSourceConnectivityChecker().check(
            sourceNetlistURL: sourceURL,
            sourceNetlistFormat: .verilog,
            ir: ir
        )

        #expect(report.status == PEXSourceConnectivityStatus.warning)
        #expect(!report.isSatisfied)
        #expect(report.diagnostics.contains { $0.contains("module boundary") })
    }

    @Test func strictConnectivityPolicyRetainsFailedReportArtifact() async throws {
        let directory = temporaryDirectory("connectivity-strict")
        defer { remove(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layoutURL = directory.appending(path: "layout.gds")
        let netlistURL = directory.appending(path: "source.cir")
        try Data("layout".utf8).write(to: layoutURL)
        try Data("R1 unrelated_a unrelated_b 1k\n".utf8).write(to: netlistURL)
        let options = PEXRunOptions(
            extractMode: .rc,
            includeCouplingCaps: true,
            minCapacitanceF: nil,
            minResistanceOhm: nil,
            maxParallelJobs: 1,
            emitRawArtifacts: true,
            emitIRJSON: true,
            strictValidation: true,
            sourceConnectivityPolicy: .strict
        )
        let request = PEXRunRequest(
            layoutURL: layoutURL,
            layoutFormat: .gds,
            sourceNetlistURL: netlistURL,
            sourceNetlistFormat: .spice,
            topCell: "TOP",
            corners: [PEXCorner(id: "tt")],
            technology: .inline(minimalTechnology()),
            backendSelection: .mock(),
            options: options,
            workingDirectory: directory
        )

        let result = try await DefaultPEXEngine.withDefaults().run(request)
        #expect(result.status == .failed)
        let reportRecord = result.artifacts.artifacts(kind: .sourceConnectivityReport, cornerID: "tt").first
        let record = try #require(reportRecord)
        let reportURL = result.manifestURL.deletingLastPathComponent().appending(path: record.relativePath.value)
        let report = try JSONDecoder().decode(PEXSourceConnectivityReport.self, from: Data(contentsOf: reportURL))
        #expect(report.status == .failed)
        #expect(result.extractorRun?.cornerResults.first?.sourceConnectivityArtifactID == record.id)
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "PEXSourceConnectivityTests-\(name)-\(UUID().uuidString)")
    }

    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Failed to clean temporary directory: \(error)")
        }
    }

    private func minimalTechnology() -> TechnologyIR {
        TechnologyIR(
            processName: "test",
            stack: [],
            logicalToPhysicalLayerMap: [:],
            vias: [],
            defaultExtractionRules: .default,
            backendHints: [:]
        )
    }
}
