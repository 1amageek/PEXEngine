import Foundation
import CircuiteFoundation
import Testing
import PEXTestSupport
@testable import PEXCore
@testable import PEXRuntime
@testable import PEXAdapters
@testable import PEXParsers
@testable import PEXPersistence

@Suite("PEX source connectivity")
struct PEXSourceConnectivityTests {
    @Test func checkerMatchesExactSpiceRootTerminals() throws {
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
        .subckt cell in out vdd
        .ends cell
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
                    nodes: [ParasiticNode(name: NodeName("vdd"), kind: .pin, instancePath: nil, coordinate: nil)],
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
        .subckt cell in out vdd
        .ends cell
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
                ParasiticNet(name: NetName("vdd"), nodes: [ParasiticNode(name: NodeName("vdd"), kind: .pin, instancePath: nil, coordinate: nil)], totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0),
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

        let result = try await DefaultPEXEngine.withTestDefaults().run(request)
        #expect(result.status == .failed)
        let reportRecord = result.artifactManifest.artifacts(kind: .sourceConnectivityReport, cornerID: "tt").first
        let record = try #require(reportRecord)
        let reportURL = result.manifestURL
            .deletingLastPathComponent()
            .appending(path: record.relativePath.stringValue)
        let report = try JSONDecoder().decode(PEXSourceConnectivityReport.self, from: Data(contentsOf: reportURL))
        #expect(report.status == .failed)
        #expect(result.extractorRun?.cornerResults.first?.sourceConnectivityArtifactID == record.id.rawValue)
    }

    @Test func repeatedLeafCannotProveTheWrongSourceOccurrence() throws {
        let root = temporaryDirectory("wrong-occurrence")
        defer { remove(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source.cir")
        try Data(".subckt TOP A\nXgood A CHILD\n.ends TOP\n.subckt CHILD A\n.ends CHILD\n".utf8).write(to: source)
        let ir = pinGraph(["A", "Xwrong:A"])
        let report = try PEXSourceConnectivityChecker().check(sourceNetlistURL: source, sourceNetlistFormat: .spice, ir: ir)
        #expect(!report.isSatisfied)
    }

    @Test func missingRequiredRootTerminalCannotBePassed() throws {
        let root = temporaryDirectory("missing-root")
        defer { remove(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source.cir")
        try Data(".subckt TOP A B\nR1 A internal 1k\n.ends TOP\n".utf8).write(to: source)
        let report = try PEXSourceConnectivityChecker().check(sourceNetlistURL: source, sourceNetlistFormat: .spice, ir: pinGraph(["A"]))
        #expect(!report.isSatisfied)
    }

    @Test func selectedTopDoesNotBorrowUnrelatedCellTerminals() throws {
        let root = temporaryDirectory("selected-top")
        defer { remove(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source.cir")
        try Data(".subckt TOP A\n.ends TOP\n.subckt UNRELATED B\n.ends UNRELATED\n".utf8).write(to: source)
        let report = try PEXSourceConnectivityChecker().check(sourceNetlistURL: source, sourceNetlistFormat: .spice,
            ir: pinGraph(["A", "B"]), topCell: "TOP")
        #expect(report.status == .failed && report.unmatchedExtractedPinNodes == ["B"])
    }

    @Test func exactNestedTerminalAndInternalSourceNodesRemainSupported() throws {
        let root = temporaryDirectory("exact-nested")
        defer { remove(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source.cir")
        try Data(".subckt TOP A\nR1 A internal 1k\nXgood A CHILD\n.ends TOP\n.subckt CHILD P\n.ends CHILD\n".utf8).write(to: source)
        let report = try PEXSourceConnectivityChecker().check(sourceNetlistURL: source, sourceNetlistFormat: .spice,
            ir: pinGraph(["A", "Xgood:P"]), topCell: "top")
        #expect(report.isSatisfied && report.sourceOnlyNodes.isEmpty)
    }

    @Test func verilogIdentifiersKeepCaseAndNamedOccurrenceIdentity() throws {
        let root = temporaryDirectory("verilog-case")
        defer { remove(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source.v")
        try Data("module TOP(input A); cell #(.WIDTH(1)) good (.P(A)); endmodule".utf8).write(to: source)
        let checker = PEXSourceConnectivityChecker()
        #expect(try checker.check(sourceNetlistURL: source, sourceNetlistFormat: .verilog,
            ir: pinGraph(["A", "good:P"]), topCell: "TOP").isSatisfied)
        for wrong in ["good:p", "bad:P", "a", "P", "cell", "good"] {
            #expect(try !checker.check(sourceNetlistURL: source, sourceNetlistFormat: .verilog,
                ir: pinGraph(["A", wrong]), topCell: "TOP").isSatisfied)
        }
    }

    @Test func escapedVerilogSourceIdentitiesDoNotBecomeLeafAliases() throws {
        let root = temporaryDirectory("escaped-verilog")
        defer { remove(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source.v")
        try Data("module TOP(input \\wire , output \\A:B ); endmodule".utf8).write(to: source)
        let checker = PEXSourceConnectivityChecker()
        #expect(try checker.check(sourceNetlistURL: source, sourceNetlistFormat: .verilog,
            ir: pinGraph(["wire", "A:B"]), topCell: "TOP").isSatisfied)
        #expect(try !checker.check(sourceNetlistURL: source, sourceNetlistFormat: .verilog,
            ir: pinGraph(["wire", "B"]), topCell: "TOP").isSatisfied)
    }

    private func pinGraph(_ names: [String]) -> ParasiticIR {
        .init(version: ParasiticIR.currentVersion, cornerID: "tt", units: .canonical,
            nets: names.map { .init(name: NetName($0), nodes: [.init(name: NodeName($0), kind: .pin, instancePath: nil, coordinate: nil)],
                totalGroundCapF: 0, totalCouplingCapF: 0, totalResistanceOhm: 0) }, elements: [], metadata: [:])
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
