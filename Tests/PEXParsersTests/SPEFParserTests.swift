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
        *INDUC
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
                *INDUC
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
    guard let url = Bundle.module.url(forResource: "fixture-manifest", withExtension: "json", subdirectory: "OpenROAD") else {
        throw OpenROADFixtureError.missingFixture("fixture-manifest.json")
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(OpenROADFixtureManifest.self, from: data)
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
