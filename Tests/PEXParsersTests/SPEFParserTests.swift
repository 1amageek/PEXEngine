import Testing
import Foundation
import CryptoKit
@testable import PEXCore
@testable import PEXParsers

@Suite("SPEF Parser Tests")
struct SPEFParserTests {
    let sampleSPEF = """
    *SPEF "IEEE 1481-1998"
    *DESIGN "top"
    *DATE "2024-01-01"
    *VENDOR "Test"
    *PROGRAM "Test"
    *VERSION "1.0"
    *DESIGN_FLOW "EXTERNAL"
    *DIVIDER /
    *DELIMITER :
    *BUS_DELIMITER [ ]
    *T_UNIT 1 NS
    *C_UNIT 1 PF
    *R_UNIT 1 OHM
    *L_UNIT 1 HENRY

    *NAME_MAP
    *1 VDD
    *2 VSS

    *PORTS
    VDD I
    VSS O

    *D_NET VDD 0.150000
    *CONN
    *I top:VDD I
    *CAP
    1 VDD:1 0.100000
    2 VDD:1 VDD:2 0.050000
    *RES
    1 VDD:1 VDD:2 10.0000
    *END

    *D_NET VSS 0.080000
    *CONN
    *I top:VSS O
    *CAP
    1 VSS:1 0.080000
    *RES
    1 VSS:1 VSS:2 5.0000
    *END
    """

    @Test func lexerTokenizes() {
        var lexer = SPEFLexer(source: sampleSPEF)
        let tokens = lexer.tokenize()
        #expect(!tokens.isEmpty)
        // First meaningful token should be *SPEF keyword
        let keywords = tokens.compactMap { t -> String? in
            if case .keyword(let kw) = t.token { return kw }
            return nil
        }
        #expect(keywords.contains("SPEF"))
        #expect(keywords.contains("DESIGN"))
        #expect(keywords.contains("D_NET"))
    }

    @Test func parserProducesTree() throws {
        var lexer = SPEFLexer(source: sampleSPEF)
        let tokens = lexer.tokenize()
        let parser = SPEFParser()
        let tree = try parser.parse(tokens: tokens)

        #expect(tree.header.designName == "top")
        #expect(tree.header.capUnit == "PF")
        #expect(tree.header.resUnit == "OHM")
        #expect(tree.nets.count == 2)
        #expect(tree.nets[0].netName == "VDD")
        #expect(tree.nets[0].capacitors.count == 2)
        #expect(tree.nets[0].resistors.count == 1)
        #expect(tree.nets[0].inductors.isEmpty)
    }

    @Test func loweringPreservesInstancePathFromInstanceConnections() throws {
        var lexer = SPEFLexer(source: sampleSPEF)
        let tree = try SPEFParser().parse(tokens: lexer.tokenize())
        let ir = try SPEFLowering().lower(tree, cornerID: "tt")
        let vdd = try #require(ir.nets.first { $0.name == NetName("VDD") })
        let instancePaths = Set(vdd.nodes.compactMap { $0.instancePath?.value })
        #expect(instancePaths == ["top"])
    }

    @Test func parserLowersInductorsToCanonicalIR() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "top"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM
        *L_UNIT 1 NH

        *D_NET net1 0.0
        *CONN
        *I net1:a I
        *INDUC
        1 net1:a net1:b 2.0
        *END
        """
        var lexer = SPEFLexer(source: spef)
        let tree = try SPEFParser().parse(tokens: lexer.tokenize())

        #expect(tree.nets[0].inductors.count == 1)

        let ir = try SPEFLowering().lower(tree, cornerID: "tt")
        let inductor = try #require(ir.elements.first { $0.kind == .inductor })
        #expect(inductor.id == "net1_L1")
        #expect(inductor.nodeA.nodeName == NodeName("net1:a"))
        #expect(inductor.nodeB?.nodeName == NodeName("net1:b"))
        #expect(abs(inductor.value - 2.0e-9) < 1e-18)
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test func parserRejectsUnsupportedTopLevelKeyword() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "top"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM

        *UNSUPPORTED
        value
        """
        var lexer = SPEFLexer(source: spef)
        let tokens = lexer.tokenize()
        let parser = SPEFParser()

        #expect(throws: SPEFParserDiagnostic.self) {
            try parser.parse(tokens: tokens)
        }
    }

    @Test func parserRejectsUnsupportedNetSection() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "top"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM

        *D_NET net1 0.5
        *CONN
        *CAP
        1 net1:a 0.5
        *DELAY
        1 net1:a net1:b 2.0
        *END
        """
        var lexer = SPEFLexer(source: spef)
        let tokens = lexer.tokenize()
        let parser = SPEFParser()

        #expect(throws: SPEFParserDiagnostic.self) {
            try parser.parse(tokens: tokens)
        }
    }

    @Test func parserRejectsInvalidLexerCharacters() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "top"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM

        @
        """
        var lexer = SPEFLexer(source: spef)
        let tokens = lexer.tokenize()

        #expect(throws: SPEFParserDiagnostic.self) {
            try SPEFParser().parse(tokens: tokens)
        }
    }

    @Test func parserRejectsUnterminatedStringLiteral() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "top
        *DIVIDER /
        """
        var lexer = SPEFLexer(source: spef)
        let tokens = lexer.tokenize()

        #expect(throws: SPEFParserDiagnostic.self) {
            try SPEFParser().parse(tokens: tokens)
        }
    }

    @Test func parserRejectsMissingRequiredHeaderFields() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "top"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *R_UNIT 1 OHM

        *D_NET net1 0.5
        *END
        """
        var lexer = SPEFLexer(source: spef)
        let tokens = lexer.tokenize()

        #expect(throws: SPEFParserDiagnostic.self) {
            try SPEFParser().parse(tokens: tokens)
        }
    }

    @Test func parserRejectsDuplicateHeaderKeyword() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "top"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *C_UNIT 1 FF
        *R_UNIT 1 OHM

        *D_NET net1 0.5
        *END
        """

        try expectParserDiagnostic(
            spef,
            contains: "Duplicate SPEF header keyword *C_UNIT"
        )
    }

    @Test func parserRejectsUnterminatedNetBlock() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "top"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM

        *D_NET net1 0.5
        *CAP
        1 net1:a 0.5
        """
        var lexer = SPEFLexer(source: spef)
        let tokens = lexer.tokenize()

        #expect(throws: SPEFParserDiagnostic.self) {
            try SPEFParser().parse(tokens: tokens)
        }
    }

    @Test func parserRejectsUnexpectedNetBlockToken() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "top"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM

        *D_NET net1 0.5
        orphan_token
        *END
        """

        try expectParserDiagnostic(
            spef,
            contains: "Unexpected SPEF token inside *D_NET net1"
        )
    }

    @Test func parserRejectsMalformedConnection() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "top"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM

        *D_NET net1 0.5
        *CONN
        *I net1:a X
        *END
        """
        var lexer = SPEFLexer(source: spef)
        let tokens = lexer.tokenize()

        #expect(throws: SPEFParserDiagnostic.self) {
            try SPEFParser().parse(tokens: tokens)
        }
    }

    @Test func parserRejectsMalformedCapacitor() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "top"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM

        *D_NET net1 0.5
        *CAP
        1 net1:a net1:b
        *END
        """
        var lexer = SPEFLexer(source: spef)
        let tokens = lexer.tokenize()

        #expect(throws: SPEFParserDiagnostic.self) {
            try SPEFParser().parse(tokens: tokens)
        }
    }

    @Test func parserRejectsMalformedResistor() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "top"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM

        *D_NET net1 0.5
        *RES
        1 net1:a net1:b
        *END
        """
        var lexer = SPEFLexer(source: spef)
        let tokens = lexer.tokenize()

        #expect(throws: SPEFParserDiagnostic.self) {
            try SPEFParser().parse(tokens: tokens)
        }
    }

    @Test func parserRejectsFractionalElementIdentifier() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "top"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM

        *D_NET net1 0.5
        *CAP
        1.5 net1:a 0.5
        *END
        """

        try expectParserDiagnostic(
            spef,
            contains: "Expected integer value for *CAP"
        )
    }

    @Test func pexParserRejectsMalformedCorpusAtRawEntrypoint() throws {
        let context = PEXParseContext(
            cornerID: "tt",
            runID: PEXRunID(),
            technology: nil,
            options: .default
        )
        #expect(throws: PEXError.self) {
            _ = try SPEFPEXParser().parse(PEXRawOutput(format: .spef, fileURLs: []), context: context)
        }

        let malformedCorpus: [(name: String, source: String)] = [
            (
                name: "empty-file",
                source: ""
            ),
            (
                name: "missing-cap-unit",
                source: """
                *SPEF "IEEE 1481-1998"
                *DESIGN "top"
                *DIVIDER /
                *DELIMITER :
                *BUS_DELIMITER [ ]
                *T_UNIT 1 NS
                *R_UNIT 1 OHM

                *D_NET net1 0.5
                *END
                """
            ),
            (
                name: "malformed-capacitor",
                source: """
                *SPEF "IEEE 1481-1998"
                *DESIGN "top"
                *DIVIDER /
                *DELIMITER :
                *BUS_DELIMITER [ ]
                *T_UNIT 1 NS
                *C_UNIT 1 PF
                *R_UNIT 1 OHM

                *D_NET net1 0.5
                *CAP
                1 net1:a net1:b
                *END
                """
            ),
            (
                name: "unsupported-section",
                source: """
                *SPEF "IEEE 1481-1998"
                *DESIGN "top"
                *DIVIDER /
                *DELIMITER :
                *BUS_DELIMITER [ ]
                *T_UNIT 1 NS
                *C_UNIT 1 PF
                *R_UNIT 1 OHM

                *D_NET net1 0.5
                *DELAY
                1 net1:a net1:b 2.0
                *END
                """
            ),
        ]

        for item in malformedCorpus {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "spef-malformed-\(item.name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "\(item.name).spef")
            try Data(item.source.utf8).write(to: file)
            do {
                _ = try SPEFPEXParser().parse(PEXRawOutput(format: .spef, fileURLs: [file]), context: context)
                #expect(Bool(false), "Malformed SPEF corpus item should fail: \(item.name)")
            } catch let error as PEXError {
                #expect(error.kind == .parseFailed, "Expected parseFailed for \(item.name), got \(error.kind)")
            }
            removeTemporaryItem(directory)
        }
    }

    @Test("A coupling cap listed reciprocally in both nets is counted exactly once")
    func reciprocalCouplingCountedOnce() throws {
        // IEEE 1481 SPEF lists a coupling cap in BOTH coupled nets' *CAP
        // sections. The lowering must emit one element per physical cap (single
        // attribution), matching the Magic path — not one element per listing.
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "reciprocal"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM

        *D_NET A 0.1
        *CONN
        *CAP
        1 A:1 B:1 0.05
        *END

        *D_NET B 0.1
        *CONN
        *CAP
        1 A:1 B:1 0.05
        *END
        """
        var lexer = SPEFLexer(source: spef)
        let tree = try SPEFParser().parse(tokens: lexer.tokenize())
        let ir = try SPEFLowering().lower(tree, cornerID: "tt")

        let couplings = ir.elements.filter { $0.kind == .coupling }
        #expect(couplings.count == 1, "a reciprocally-listed coupling must produce exactly one element")
        // Counted-once invariant: per-net coupling totals sum to the element sum,
        // and that equals the single physical value (not double).
        let perNetSum = ir.nets.map(\.totalCouplingCapF).reduce(0, +)
        let elementSum = couplings.map(\.value).reduce(0, +)
        #expect(abs(perNetSum - elementSum) <= 1e-21)
        #expect(abs(elementSum - 0.05e-12) <= 1e-21, "the coupling must carry the physical value once, not doubled")
    }

    @Test("Parallel coupling caps with the same endpoints are preserved while reciprocal listings are deduped")
    func parallelCouplingsWithSameEndpointsArePreserved() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "parallel"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM

        *D_NET A 0.1
        *CONN
        *CAP
        1 A:1 B:1 0.05
        2 A:1 B:1 0.05
        *END

        *D_NET B 0.1
        *CONN
        *CAP
        1 A:1 B:1 0.05
        2 A:1 B:1 0.05
        *END
        """
        var lexer = SPEFLexer(source: spef)
        let tree = try SPEFParser().parse(tokens: lexer.tokenize())
        let ir = try SPEFLowering().lower(tree, cornerID: "tt")

        let couplings = ir.elements.filter { $0.kind == .coupling }
        #expect(couplings.count == 2, "two physical parallel caps must not collapse into one endpoint-pair entry")

        let perNetSum = ir.nets.map(\.totalCouplingCapF).reduce(0, +)
        let elementSum = couplings.map(\.value).reduce(0, +)
        #expect(abs(perNetSum - elementSum) <= 1e-21)
        #expect(abs(elementSum - 0.10e-12) <= 1e-21)
    }

    @Test("A coupling listed reciprocally with inconsistent values fails loudly")
    func reciprocalCouplingValueMismatchThrows() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "mismatch"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM

        *D_NET A 0.1
        *CONN
        *CAP
        1 A:1 B:1 0.05
        *END

        *D_NET B 0.1
        *CONN
        *CAP
        1 A:1 B:1 0.07
        *END
        """
        var lexer = SPEFLexer(source: spef)
        let tree = try SPEFParser().parse(tokens: lexer.tokenize())
        #expect(throws: PEXError.self) {
            _ = try SPEFLowering().lower(tree, cornerID: "tt")
        }
    }

    @Test func openROADRCXFixturesParseAndLowerToExpectedSummaries() throws {
        let manifest = try openROADFixtureManifest()
        #expect(manifest.schemaVersion == 1)
        #expect(!manifest.fixtures.isEmpty)

        for fixture in manifest.fixtures {
            let url = try openROADFixtureURL(fileName: fixture.fileName)
            let data = try Data(contentsOf: url)
            #expect(sha256Hex(data) == fixture.sha256)

            let source = String(decoding: data, as: UTF8.self)
            var lexer = SPEFLexer(source: source, fileName: fixture.fileName)
            let tree = try SPEFParser().parse(tokens: lexer.tokenize())

            #expect(tree.header.designName == fixture.designName)
            #expect(tree.nameMap.count == fixture.parseSummary.nameMapCount)
            #expect(tree.ports.count == fixture.parseSummary.portCount)
            #expect(tree.nets.count == fixture.parseSummary.netCount)
            #expect(tree.nets.reduce(0) { $0 + $1.connections.count } == fixture.parseSummary.connectionCount)
            #expect(tree.nets.reduce(0) { $0 + $1.capacitors.count } == fixture.parseSummary.capacitorCount)
            #expect(tree.nets.reduce(0) { $0 + $1.resistors.count } == fixture.parseSummary.resistorCount)

            let ir = try SPEFLowering().lower(tree, cornerID: "openroad")
            let validation = ParasiticIRValidator().validate(ir)
            #expect(validation.isValid, "OpenROAD fixture should lower to valid ParasiticIR: \(fixture.fileName)")
            #expect(ir.nets.count == fixture.loweredSummary.netCount)
            #expect(ir.elements.count == fixture.loweredSummary.elementCount)
            #expect(ir.elements.filter { $0.kind == .capacitor }.count == fixture.loweredSummary.capacitorElementCount)
            #expect(ir.elements.filter { $0.kind == .coupling }.count == fixture.loweredSummary.couplingElementCount)
            #expect(ir.elements.filter { $0.kind == .resistor }.count == fixture.loweredSummary.resistorElementCount)
            #expect(isClose(totalGroundCap(in: ir), fixture.loweredSummary.totalGroundCapF, tolerance: fixture.loweredSummary.capTolerance))
            #expect(isClose(totalCouplingCap(in: ir), fixture.loweredSummary.totalCouplingCapF, tolerance: fixture.loweredSummary.capTolerance))
            #expect(isClose(totalResistance(in: ir), fixture.loweredSummary.totalResistanceOhm, tolerance: 1e-9))
        }
    }

    @Test func openROADRCXFixtureCorpusQualifiesThroughPublicRunner() throws {
        let manifestURL = try openROADFixtureManifestURL()
        let report = try SPEFCorpusRunner().run(manifestURL: manifestURL)

        #expect(report.status == "passed")
        #expect(report.summary.caseCount == 7)
        #expect(report.summary.failedCaseCount == 0)
        #expect(report.qualification.qualified)
        #expect(report.qualification.failures.isEmpty)
        #expect(report.summary.coverageTagCounts["pex.spef.openroad"] == 7)
        #expect(report.summary.coverageTagCounts["pex.extract.openrcx"] == 7)
        #expect(report.summary.coverageTagCounts["pex.physical-value"] == 7)
        #expect(report.summary.coverageTagCounts["pex.spef.coordinates"] == 1)
        #expect(report.summary.coverageTagCounts["pex.spef.net-name-consistency"] == 1)
        #expect(report.summary.coverageTagCounts["pex.spef.no-merging"] == 1)
        #expect(report.summary.coverageTagCounts["pex.spef.short-resover"] == 1)
        #expect(report.toolEvidence.qualification.observedCounts["caseCount"] == 7)
        #expect(report.toolEvidence.qualification.observedCounts["requiredCoverageTagCount"] == 14)
        #expect(report.toolEvidence.qualification.observedCounts["coveredRequiredCoverageTagCount"] == 14)
    }

    @Test func spefCorpusReportClassifiesParseAndPhysicalBoundFailures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "spef-negative-corpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeTemporaryItem(directory) }

        let physicalData = Data(sampleSPEF.utf8)
        let physicalURL = directory.appending(path: "physical-bound.spef")
        try physicalData.write(to: physicalURL)

        let malformedData = Data("""
        *SPEF "IEEE 1481-1998"
        *DESIGN "bad"
        """.utf8)
        let malformedURL = directory.appending(path: "malformed.spef")
        try malformedData.write(to: malformedURL)

        let manifest = SPEFCorpus.Manifest(
            schemaVersion: 1,
            sourceRepository: "local-negative-corpus",
            pinnedCommit: "local",
            sourceDirectory: directory.path(percentEncoded: false),
            license: "test-fixture",
            qualificationPolicy: SPEFCorpus.QualificationPolicy(
                requiredCoverageTags: [
                    "pex.negative.parse-failure",
                    "pex.negative.physical-bound",
                ]
            ),
            fixtures: [
                SPEFCorpus.Fixture(
                    fileName: "malformed.spef",
                    sourcePath: "local/malformed.spef",
                    gitBlobSHA: "local",
                    sha256: sha256Hex(malformedData),
                    byteCount: malformedData.count,
                    designName: "bad",
                    coverageTags: ["pex.negative.parse-failure"],
                    parseSummary: SPEFCorpus.ParseSummary(
                        nameMapCount: 0,
                        portCount: 0,
                        netCount: 0,
                        connectionCount: 0,
                        capacitorCount: 0,
                        resistorCount: 0
                    ),
                    loweredSummary: SPEFCorpus.LoweredSummary(
                        netCount: 0,
                        elementCount: 0,
                        capacitorElementCount: 0,
                        couplingElementCount: 0,
                        resistorElementCount: 0,
                        totalGroundCapF: 0,
                        totalCouplingCapF: 0,
                        totalResistanceOhm: 0,
                        capTolerance: 1e-24
                    )
                ),
                SPEFCorpus.Fixture(
                    fileName: "physical-bound.spef",
                    sourcePath: "local/physical-bound.spef",
                    gitBlobSHA: "local",
                    sha256: sha256Hex(physicalData),
                    byteCount: physicalData.count,
                    designName: "top",
                    coverageTags: ["pex.negative.physical-bound"],
                    parseSummary: SPEFCorpus.ParseSummary(
                        nameMapCount: 2,
                        portCount: 2,
                        netCount: 2,
                        connectionCount: 2,
                        capacitorCount: 3,
                        resistorCount: 2
                    ),
                    loweredSummary: SPEFCorpus.LoweredSummary(
                        netCount: 2,
                        elementCount: 5,
                        capacitorElementCount: 3,
                        couplingElementCount: 0,
                        resistorElementCount: 2,
                        totalGroundCapF: 9e-12,
                        totalCouplingCapF: 0,
                        totalResistanceOhm: 15,
                        capTolerance: 1e-20
                    )
                ),
            ]
        )
        let manifestURL = directory.appending(path: "fixture-manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL)

        let report = try SPEFCorpusRunner().run(manifestURL: manifestURL)

        #expect(report.status == "failed")
        #expect(report.summary.caseCount == 2)
        #expect(report.summary.failedCaseCount == 2)
        #expect(report.summary.failureCategoryCounts["parse_failure"] == 1)
        #expect(report.summary.failureCategoryCounts["physical_bound_mismatch"] == 1)
        #expect(report.summary.failureCodeCounts["parse_failed"] == 1)
        #expect(report.summary.failureCodeCounts["total_ground_cap_mismatch"] == 1)
        #expect(report.toolEvidence.qualification.observedCounts["failureOccurrenceCount"] == 2)
        #expect(report.toolEvidence.qualification.observedCounts["failureCategoryCount"] == 2)
        #expect(report.toolEvidence.qualification.observedCounts["failureCategoryKindCount"] == 2)
        #expect(report.toolEvidence.qualification.observedCounts["failureCodeCount"] == 2)
        #expect(report.toolEvidence.qualification.observedCounts["failureCodeKindCount"] == 2)

        let parseResult = try #require(report.caseResults.first { $0.fileName == "malformed.spef" })
        let parseFailure = try #require(parseResult.failures.first { $0.code == "parse_failed" })
        #expect(parseFailure.category == "parse_failure")
        #expect(parseFailure.suggestedActions.contains("inspect_spef_syntax"))

        let physicalResult = try #require(report.caseResults.first { $0.fileName == "physical-bound.spef" })
        let physicalFailure = try #require(physicalResult.failures.first { $0.code == "total_ground_cap_mismatch" })
        #expect(physicalFailure.category == "physical_bound_mismatch")
        #expect(physicalFailure.observedDouble != nil)
        #expect(physicalFailure.expectedDouble == 9e-12)
        #expect(physicalFailure.tolerance == 1e-20)
        #expect(physicalFailure.suggestedActions.contains("check_extractor_units"))

        let packet = SPEFCorpusEvidencePacketBuilder().build(report: report, packetID: "negative-packet")
        #expect(packet.packetID == "negative-packet")
        #expect(packet.confidence.level == .medium)
        #expect(packet.inputs.contains { $0.kind == "spef-fixture" && $0.sha256 != nil })
        #expect(packet.diagnostics.contains { $0.category == "parse_failure" && $0.caseID == "malformed.spef" })
        #expect(packet.diagnostics.contains { $0.category == "physical_bound_mismatch" && $0.expectedValue == 9e-12 })
        #expect(packet.decisionHints.contains { $0.action == "inspect_spef_syntax" })
        #expect(packet.decisionHints.contains { $0.action == "check_extractor_units" })
    }

    @Test func connectionsParsedCorrectly() throws {
        var lexer = SPEFLexer(source: sampleSPEF)
        let tokens = lexer.tokenize()
        let parser = SPEFParser()
        let tree = try parser.parse(tokens: tokens)

        // *I and *P markers must be parsed as connections, not ignored
        let vddNet = tree.nets[0]
        #expect(vddNet.connections.count == 1)
        #expect(vddNet.connections[0].type == .instancePin)
        #expect(vddNet.connections[0].direction == .input)

        let vssNet = tree.nets[1]
        #expect(vssNet.connections.count == 1)
        #expect(vssNet.connections[0].type == .instancePin)
        #expect(vssNet.connections[0].direction == .output)
    }

    @Test func scaleFactorsStoredInHeader() throws {
        let scaledSPEF = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "scaled"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 10 NS
        *C_UNIT 100 FF
        *R_UNIT 1 KOHM

        *D_NET net1 0.5
        *CONN
        *CAP
        1 net1:a 0.5
        *RES
        1 net1:a net1:b 2.0
        *END
        """
        var lexer = SPEFLexer(source: scaledSPEF)
        let tokens = lexer.tokenize()
        let parser = SPEFParser()
        let tree = try parser.parse(tokens: tokens)

        #expect(tree.header.capUnit == "FF")
        #expect(tree.header.capScaleFactor == 100.0)
        #expect(tree.header.resUnit == "KOHM")
        #expect(tree.header.resScaleFactor == 1.0)
        #expect(tree.header.timeUnit == "NS")
        #expect(tree.header.timeScaleFactor == 10.0)
    }

    @Test func loweringAppliesScaleFactors() throws {
        // *C_UNIT 100 FF means each value unit = 100 FF = 100e-15 F
        // *R_UNIT 1 KOHM means each value unit = 1 KOHM = 1000 OHM
        let scaledSPEF = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "scaled"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 100 FF
        *R_UNIT 1 KOHM

        *D_NET net1 0.5
        *CONN
        *CAP
        1 net1:a 0.5
        *RES
        1 net1:a net1:b 2.0
        *END
        """
        var lexer = SPEFLexer(source: scaledSPEF)
        let tokens = lexer.tokenize()
        let parser = SPEFParser()
        let tree = try parser.parse(tokens: tokens)
        let lowering = SPEFLowering()
        let ir = try lowering.lower(tree, cornerID: "tt")

        // Cap: 0.5 * 100 * 1e-15 = 5e-14 F
        let groundCaps = ir.elements.filter { $0.kind == .capacitor && $0.nodeB == nil }
        #expect(groundCaps.count == 1)
        #expect(abs(groundCaps[0].value - 5e-14) < 1e-20)

        // Res: 2.0 * 1 * 1e3 = 2000 OHM
        let resistors = ir.elements.filter { $0.kind == .resistor }
        #expect(resistors.count == 1)
        #expect(abs(resistors[0].value - 2000.0) < 0.01)
    }

    @Test func loweringAppliesRunOptionFiltersToElementsAndSummaries() throws {
        var lexer = SPEFLexer(source: sampleSPEF)
        let tree = try SPEFParser().parse(tokens: lexer.tokenize())
        let options = PEXRunOptions(
            extractMode: .rc,
            includeCouplingCaps: false,
            minCapacitanceF: 9e-14,
            minResistanceOhm: 6.0,
            maxParallelJobs: 1,
            emitRawArtifacts: true,
            emitIRJSON: true,
            strictValidation: false
        )

        let ir = try SPEFLowering().lower(tree, cornerID: "tt", options: options)

        #expect(ir.elements.count == 2)
        #expect(ir.elements.filter { $0.kind == .capacitor }.count == 1)
        #expect(ir.elements.filter { $0.kind == .coupling }.isEmpty)
        #expect(ir.elements.filter { $0.kind == .resistor }.count == 1)
        #expect(isClose(totalGroundCap(in: ir), 1e-13, tolerance: 1e-18))
        #expect(totalCouplingCap(in: ir) == 0)
        #expect(totalResistance(in: ir) == 10)
    }

    @Test func loweringIncludesSameNetCapacitorsInNetSummaries() throws {
        var lexer = SPEFLexer(source: sampleSPEF)
        let tree = try SPEFParser().parse(tokens: lexer.tokenize())

        let ir = try SPEFLowering().lower(tree, cornerID: "tt")

        let sameNetCap = try #require(ir.elements.first {
            $0.kind == .capacitor && $0.nodeB?.netName == $0.nodeA.netName
        })
        #expect(isClose(sameNetCap.value, 5e-14, tolerance: 1e-20))
        #expect(isClose(totalGroundCap(in: ir), 2.3e-13, tolerance: 1e-18))
    }

    @Test func loweringHonorsExtractMode() throws {
        var lexer = SPEFLexer(source: sampleSPEF)
        let tree = try SPEFParser().parse(tokens: lexer.tokenize())
        let cOnly = PEXRunOptions(
            extractMode: .cOnly,
            includeCouplingCaps: true,
            minCapacitanceF: nil,
            minResistanceOhm: nil,
            maxParallelJobs: 1,
            emitRawArtifacts: true,
            emitIRJSON: true,
            strictValidation: false
        )
        let rOnly = PEXRunOptions(
            extractMode: .rOnly,
            includeCouplingCaps: true,
            minCapacitanceF: nil,
            minResistanceOhm: nil,
            maxParallelJobs: 1,
            emitRawArtifacts: true,
            emitIRJSON: true,
            strictValidation: false
        )

        let cOnlyIR = try SPEFLowering().lower(tree, cornerID: "tt", options: cOnly)
        let rOnlyIR = try SPEFLowering().lower(tree, cornerID: "tt", options: rOnly)

        #expect(cOnlyIR.elements.allSatisfy { $0.kind != .resistor })
        #expect(rOnlyIR.elements.allSatisfy { $0.kind == .resistor })
        #expect(totalResistance(in: cOnlyIR) == 0)
        #expect(totalGroundCap(in: rOnlyIR) == 0)
        #expect(totalCouplingCap(in: rOnlyIR) == 0)
    }

    @Test func rOnlyStillRejectsReciprocalCouplingMismatch() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "mismatch"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM

        *D_NET A 0.1
        *CONN
        *CAP
        1 A:1 B:1 0.05
        *RES
        1 A:1 A:2 1.0
        *END

        *D_NET B 0.1
        *CONN
        *CAP
        1 A:1 B:1 0.06
        *RES
        1 B:1 B:2 1.0
        *END
        """
        var lexer = SPEFLexer(source: spef)
        let tree = try SPEFParser().parse(tokens: lexer.tokenize())
        let options = PEXRunOptions(
            extractMode: .rOnly,
            includeCouplingCaps: true,
            minCapacitanceF: nil,
            minResistanceOhm: nil,
            maxParallelJobs: 1,
            emitRawArtifacts: true,
            emitIRJSON: true,
            strictValidation: false
        )

        #expect(throws: PEXError.self) {
            try SPEFLowering().lower(tree, cornerID: "tt", options: options)
        }
    }

    @Test func loweringProducesIR() throws {
        var lexer = SPEFLexer(source: sampleSPEF)
        let tokens = lexer.tokenize()
        let parser = SPEFParser()
        let tree = try parser.parse(tokens: tokens)
        let lowering = SPEFLowering()
        let ir = try lowering.lower(tree, cornerID: "tt")

        #expect(ir.nets.count == 2)
        #expect(!ir.elements.isEmpty)
        #expect(ir.cornerID.value == "tt")
        #expect(ir.units == .canonical)

        // Check unit conversion: PF -> F
        let groundCaps = ir.elements.filter { $0.kind == .capacitor && $0.nodeB == nil }
        for cap in groundCaps {
            #expect(cap.value < 1e-9, "Values should be in Farads (very small)")
        }
    }

    @Test func loweringClassifiesCrossNetCapacitors() throws {
        let spef = """
        *SPEF "IEEE 1481-1998"
        *DESIGN "coupling"
        *DIVIDER /
        *DELIMITER :
        *BUS_DELIMITER [ ]
        *T_UNIT 1 NS
        *C_UNIT 1 PF
        *R_UNIT 1 OHM

        *D_NET VDD 0.1
        *CONN
        *CAP
        1 VDD:1 VSS:1 0.1
        *END

        *D_NET VSS 0.0
        *CONN
        *END
        """
        var lexer = SPEFLexer(source: spef)
        let tree = try SPEFParser().parse(tokens: lexer.tokenize())
        let ir = try SPEFLowering().lower(tree, cornerID: "tt")

        let coupling = try #require(ir.elements.first { $0.kind == .coupling })
        let vddNet = try #require(ir.nets.first { $0.name == NetName("VDD") })
        #expect(coupling.nodeA.netName == NetName("VDD"))
        #expect(coupling.nodeB?.netName == NetName("VSS"))
        #expect(!vddNet.nodes.contains { $0.name == NodeName("VSS:1") })
    }

    @Test func endToEndSPEFPEXParser() throws {
        // Write sample SPEF to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let spefURL = tempDir.appending(path: "test_\(UUID().uuidString).spef")
        try Data(sampleSPEF.utf8).write(to: spefURL)
        defer { removeTemporaryItem(spefURL) }

        let raw = PEXRawOutput(format: .spef, fileURLs: [spefURL], logURL: nil, metadata: [:])
        let context = PEXParseContext(
            cornerID: "tt",
            runID: PEXRunID(),
            technology: nil,
            options: .default
        )

        let parser = SPEFPEXParser()
        let ir = try parser.parse(raw, context: context)
        #expect(ir.nets.count == 2)
    }
}

private func expectParserDiagnostic(_ spef: String, contains messageFragment: String) throws {
    var lexer = SPEFLexer(source: spef)
    let tokens = lexer.tokenize()

    do {
        _ = try SPEFParser().parse(tokens: tokens)
        Issue.record("Expected SPEFParserDiagnostic containing '\(messageFragment)'")
    } catch let diagnostic as SPEFParserDiagnostic {
        #expect(diagnostic.message.contains(messageFragment))
    }
}

private func removeTemporaryItem(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
    }
}

private struct OpenROADFixtureManifest: Decodable, Sendable {
    let schemaVersion: Int
    let sourceRepository: String
    let pinnedCommit: String
    let sourceDirectory: String
    let license: String
    let fixtures: [OpenROADFixtureExpectation]
}

private struct OpenROADFixtureExpectation: Decodable, Sendable {
    let fileName: String
    let sourcePath: String
    let gitBlobSHA: String
    let sha256: String
    let byteCount: Int
    let designName: String
    let parseSummary: OpenROADFixtureParseSummary
    let loweredSummary: OpenROADFixtureLoweredSummary
}

private struct OpenROADFixtureParseSummary: Decodable, Sendable {
    let nameMapCount: Int
    let portCount: Int
    let netCount: Int
    let connectionCount: Int
    let capacitorCount: Int
    let resistorCount: Int
}

private struct OpenROADFixtureLoweredSummary: Decodable, Sendable {
    let netCount: Int
    let elementCount: Int
    let capacitorElementCount: Int
    let couplingElementCount: Int
    let resistorElementCount: Int
    let totalGroundCapF: Double
    let totalCouplingCapF: Double
    let totalResistanceOhm: Double
    let capTolerance: Double
}

private enum OpenROADFixtureError: Error {
    case missingFixture(String)
}

private func openROADFixtureManifest() throws -> OpenROADFixtureManifest {
    let url = try openROADFixtureManifestURL()
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(OpenROADFixtureManifest.self, from: data)
}

private func openROADFixtureManifestURL() throws -> URL {
    guard let url = Bundle.module.url(forResource: "fixture-manifest", withExtension: "json", subdirectory: "OpenROAD") else {
        throw OpenROADFixtureError.missingFixture("fixture-manifest.json")
    }
    return url
}

private func openROADFixtureURL(fileName: String) throws -> URL {
    guard let url = Bundle.module.url(forResource: fileName, withExtension: nil, subdirectory: "OpenROAD") else {
        throw OpenROADFixtureError.missingFixture(fileName)
    }
    return url
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}

private func totalGroundCap(in ir: ParasiticIR) -> Double {
    ir.nets.reduce(0) { $0 + $1.totalGroundCapF }
}

private func totalCouplingCap(in ir: ParasiticIR) -> Double {
    ir.nets.reduce(0) { $0 + $1.totalCouplingCapF }
}

private func totalResistance(in ir: ParasiticIR) -> Double {
    ir.nets.reduce(0) { $0 + $1.totalResistanceOhm }
}

private func isClose(_ lhs: Double, _ rhs: Double, tolerance: Double) -> Bool {
    abs(lhs - rhs) <= tolerance
}
