import Testing
import Foundation
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

    @Test func endToEndSPEFPEXParser() throws {
        // Write sample SPEF to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let spefURL = tempDir.appending(path: "test_\(UUID().uuidString).spef")
        try Data(sampleSPEF.utf8).write(to: spefURL)
        defer { try? FileManager.default.removeItem(at: spefURL) }

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
