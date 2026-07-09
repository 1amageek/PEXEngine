import Foundation
import Testing
@testable import PEXCore
@testable import PEXParsers

@Suite("DSPFPEXParser")
struct DSPFPEXParserTests {
    private func options(
        extractMode: PEXExtractMode = .rc,
        includeCoupling: Bool = true,
        minCapacitanceF: Double? = nil,
        minResistanceOhm: Double? = nil
    ) -> PEXRunOptions {
        PEXRunOptions(
            extractMode: extractMode,
            includeCouplingCaps: includeCoupling,
            minCapacitanceF: minCapacitanceF,
            minResistanceOhm: minResistanceOhm,
            maxParallelJobs: 1,
            emitRawArtifacts: false,
            emitIRJSON: false,
            strictValidation: true
        )
    }

    private func parse(
        _ dspf: String,
        extractMode: PEXExtractMode = .rc,
        includeCoupling: Bool = true,
        minCapacitanceF: Double? = nil,
        minResistanceOhm: Double? = nil,
        metadata: [String: String] = [:]
    ) throws -> ParasiticIR {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "dspfpex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { removeTemporaryItem(dir) }

        let file = dir.appending(path: "extracted.dspf")
        try Data(dspf.utf8).write(to: file)
        let raw = PEXRawOutput(format: .dspf, fileURLs: [file], metadata: metadata)
        let context = PEXParseContext(
            cornerID: PEXCornerID("tt"),
            runID: PEXRunID(),
            technology: nil,
            options: options(
                extractMode: extractMode,
                includeCoupling: includeCoupling,
                minCapacitanceF: minCapacitanceF,
                minResistanceOhm: minResistanceOhm
            )
        )
        return try DSPFPEXParser().parse(raw, context: context)
    }

    @Test("DSPF resistor-connected nodes lower into one canonical net")
    func resistorConnectedNodesLowerIntoOneNet() throws {
        let ir = try parse("""
        *|DSPF 1.0
        .subckt inv A Y VDD VSS
        *|P Y O 0.0 0.0
        RY1 Y:1 Y:2 12.5
        CY1 Y:2 0 4.2f
        .ends inv
        """)

        #expect(ir.metadata["sourceFormat"] == "dspf")
        #expect(ir.nets.count == 1)
        let net = try #require(ir.nets.first)
        #expect(net.name.value == "Y")
        #expect(Set(net.nodes.map(\.name.value)) == ["Y:1", "Y:2"])
        #expect(abs(net.totalResistanceOhm - 12.5) < 1e-9)
        #expect(abs(net.totalGroundCapF - 4.2e-15) < 1e-21)
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("DSPF coupling capacitors are lowered and counted once")
    func couplingCapacitorLowersAcrossNets() throws {
        let ir = try parse("""
        CXY Y:1 A:1 2.5f
        """)

        #expect(ir.nets.count == 2)
        #expect(ir.elements.count == 1)
        let element = try #require(ir.elements.first)
        #expect(element.id == "CXY")
        #expect(element.kind == .coupling)
        #expect(element.nodeA.netName.value == "Y")
        #expect(element.nodeB?.netName.value == "A")
        #expect(abs(ir.nets.map(\.totalCouplingCapF).reduce(0, +) - 2.5e-15) < 1e-21)
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("DSPF inductors are lowered to canonical IR")
    func inductorLowersToCanonicalIR() throws {
        let ir = try parse("""
        Lseg OUT:1 OUT:2 4n
        """)

        #expect(ir.nets.count == 1)
        #expect(ir.elements.count == 1)
        let element = try #require(ir.elements.first)
        #expect(element.id == "Lseg")
        #expect(element.kind == .inductor)
        #expect(element.nodeA.netName.value == "OUT")
        #expect(element.nodeB?.netName.value == "OUT")
        #expect(abs(element.value - 4e-9) < 1e-18)
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("DSPF parser strips inline annotations and joins continuation lines")
    func annotationsAndContinuationLines() throws {
        let ir = try parse("""
        R1 OUT:1
        + OUT:2 3.5 $ resistance annotation
        C1 OUT:2 0 1.25f *|S OUT
        """)

        #expect(ir.elements.count == 2)
        let net = try #require(ir.nets.first)
        #expect(net.name.value == "OUT")
        #expect(abs(net.totalResistanceOhm - 3.5) < 1e-9)
        #expect(abs(net.totalGroundCapF - 1.25e-15) < 1e-21)
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("DSPF includeCouplingCaps=false keeps ground caps and drops coupling")
    func dropsCouplingWhenNotRequested() throws {
        let ir = try parse("""
        C0 Y:1 0 1f
        C1 Y:1 A:1 2f
        """, includeCoupling: false)

        #expect(ir.elements.count == 1)
        #expect(ir.elements.first?.id == "C0")
        #expect(ir.elements.first?.kind == .capacitor)
        #expect(ir.elements.first?.nodeB == nil)
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("DSPF parser applies extractMode and minimum thresholds")
    func extractionOptionsFilterElementsAndModes() throws {
        let dspf = """
        Ckeep Y:1 0 5f
        Cdrop Y:1 0 0.2f
        Ccross Y:1 A:1 6f
        Rkeep Y:1 Y:2 10
        Rdrop Y:2 Y:3 0.1
        Lkeep Y:2 Y:4 3n
        """

        let filtered = try parse(
            dspf,
            minCapacitanceF: 1e-15,
            minResistanceOhm: 1.0
        )
        #expect(Set(filtered.elements.map(\.id)) == ["Ckeep", "Ccross", "Rkeep", "Lkeep"])
        #expect(abs(filtered.nets.map(\.totalGroundCapF).reduce(0, +) - 5e-15) < 1e-21)
        #expect(abs(filtered.nets.map(\.totalCouplingCapF).reduce(0, +) - 6e-15) < 1e-21)
        #expect(abs(filtered.nets.map(\.totalResistanceOhm).reduce(0, +) - 10.0) < 1e-9)
        #expect(filtered.elements.contains { $0.kind == .inductor })
        #expect(ParasiticIRValidator().validate(filtered).isValid)

        let capacitanceOnly = try parse(dspf, extractMode: .cOnly)
        #expect(!capacitanceOnly.elements.contains { $0.kind == .resistor })
        #expect(!capacitanceOnly.elements.contains { $0.kind == .inductor })
        #expect(capacitanceOnly.elements.contains { $0.kind == .capacitor })
        #expect(capacitanceOnly.elements.contains { $0.kind == .coupling })
        #expect(abs(capacitanceOnly.nets.map(\.totalResistanceOhm).reduce(0, +)) < 1e-12)
        #expect(ParasiticIRValidator().validate(capacitanceOnly).isValid)

        let resistanceOnly = try parse(dspf, extractMode: .rOnly)
        #expect(resistanceOnly.elements.allSatisfy { $0.kind == .resistor })
        #expect(!resistanceOnly.elements.contains { $0.kind == .inductor })
        #expect(abs(resistanceOnly.nets.map(\.totalGroundCapF).reduce(0, +)) < 1e-24)
        #expect(abs(resistanceOnly.nets.map(\.totalCouplingCapF).reduce(0, +)) < 1e-24)
        #expect(ParasiticIRValidator().validate(resistanceOnly).isValid)
    }

    @Test("DSPF parser preserves source capacitor element IDs")
    func preservesSourceCapacitorElementIDs() throws {
        let ir = try parse("""
        Cload OUT:1 0 1f
        Ccross OUT:1 IN:1 2f
        """)

        #expect(Set(ir.elements.map(\.id)) == ["Cload", "Ccross"])
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("DSPF parser fails loud on malformed numeric values")
    func malformedValueFails() throws {
        #expect(throws: PEXError.self) {
            _ = try parse("C0 Y:1 0 invalid")
        }
    }

    @Test("DSPF parser rejects truncated parasitic element lines")
    func truncatedElementLineFails() throws {
        #expect(throws: PEXError.self) {
            _ = try parse("R0 Y:1 Y:2")
        }
    }

    @Test("DSPF parser rejects non-DSPF raw output format")
    func parserRejectsWrongRawOutputFormat() throws {
        let context = PEXParseContext(
            cornerID: PEXCornerID("tt"),
            runID: PEXRunID(),
            technology: nil,
            options: options()
        )
        let raw = PEXRawOutput(format: .spef, fileURLs: [])

        do {
            _ = try DSPFPEXParser().parse(raw, context: context)
            Issue.record("Expected DSPF parser to reject non-DSPF raw output format")
        } catch let error as PEXError {
            #expect(error.kind == .parseFailed)
            #expect(error.message.contains("raw output format 'spef'"))
        } catch {
            Issue.record("Expected PEXError.parseFailed, got \(error)")
        }
    }

    @Test("DSPF hierarchy selects the deterministic top subckt and records subckt metadata")
    func hierarchySelectsTopSubcktAndRecordsMetadata() throws {
        let ir = try parse("""
        .subckt leaf N VSS
        Rleaf N:1 N:2 99
        Cleaf N:2 0 9f
        .ends leaf
        .subckt top A Y VSS
        *|P Y O 10.0 20.0
        Rtop Y:1 Y:2 12
        Ctop Y:2 0 3f
        .ends top
        """)

        #expect(ir.metadata["dspf.topSubckt"] == "top")
        #expect(ir.metadata["dspf.topSubcktSelection"] == "last-element-bearing-subckt")
        #expect(Set(ir.elements.map(\.id)) == ["Rtop", "Ctop"])

        let subckts = try decodeMetadata([DSPFSubcktMetadata].self, from: ir, key: "dspf.subckts")
        #expect(subckts.map(\.name) == ["leaf", "top"])
        #expect(subckts.first { $0.name == "leaf" }?.elementCount == 2)
        #expect(subckts.first { $0.name == "top" }?.elementCount == 2)

        let pinNode = try #require(ir.nets.first?.nodes.first { $0.name.value == "Y:1" })
        #expect(pinNode.kind == .pin)
        #expect(pinNode.coordinate == Point2D(x: 10.0, y: 20.0))
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("DSPF explicit topSubckt metadata selects a non-last subckt")
    func explicitTopSubcktMetadataSelectsRequestedSubckt() throws {
        let ir = try parse("""
        .subckt leaf N VSS
        Rleaf N:1 N:2 9
        .ends leaf
        .subckt top Y VSS
        Rtop Y:1 Y:2 12
        .ends top
        """, metadata: ["topSubckt": "leaf"])

        #expect(ir.metadata["dspf.topSubckt"] == "leaf")
        #expect(ir.metadata["dspf.topSubcktSelection"] == "explicit")
        #expect(Set(ir.elements.map(\.id)) == ["Rleaf"])
        #expect(ir.nets.first?.name.value == "N")
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("DSPF annotations are retained as structured metadata and applied where IR supports them")
    func annotationsBecomeMetadataAndNodeAttributes() throws {
        let ir = try parse("""
        .subckt top A Y VSS
        *|P Y O 10.0 20.0
        *|I XU1 inv 1.5 2.5 R0
        *|S XU1/Y:1 3.0 4.0
        R1 XU1/Y:1 XU1/Y:2 5
        C1 XU1/Y:2 0 1f
        .ends top
        """)

        #expect(ir.metadata["dspf.annotation.pin.count"] == "1")
        #expect(ir.metadata["dspf.annotation.instance.count"] == "1")
        #expect(ir.metadata["dspf.annotation.subnode.count"] == "1")

        let annotations = try decodeMetadata([DSPFAnnotationMetadata].self, from: ir, key: "dspf.annotations")
        #expect(Set(annotations.map(\.kind)) == ["P", "I", "S"])
        #expect(annotations.first { $0.kind == "S" }?.target == "XU1/Y:1")
        #expect(annotations.first { $0.kind == "I" }?.coordinate == DSPFCoordinateMetadata(x: 1.5, y: 2.5))

        let annotatedNode = try #require(ir.nets.first?.nodes.first { $0.name.value == "XU1/Y:1" })
        #expect(annotatedNode.instancePath?.value == "XU1")
        #expect(annotatedNode.coordinate == Point2D(x: 3.0, y: 4.0))
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("DSPF .param values substitute simple numeric identifiers with SPICE units")
    func paramValuesSubstituteNumericIdentifiers() throws {
        let ir = try parse("""
        .param global_cap=2f
        .subckt top Y VSS
        .param rseg=12.5 cap_alias=global_cap cseg=cap_alias
        R1 Y:1 Y:2 RSEG
        C1 Y:2 0 {cseg}
        .ends top
        """)

        let net = try #require(ir.nets.first)
        #expect(abs(net.totalResistanceOhm - 12.5) < 1e-9)
        #expect(abs(net.totalGroundCapF - 2e-15) < 1e-21)
        #expect(ir.metadata["dspf.param.count"] == "4")

        let params = try decodeMetadata([DSPFParameterMetadata].self, from: ir, key: "dspf.params")
        #expect(params.contains { $0.name == "global_cap" && $0.value == "2f" })
        #expect(params.contains { $0.name == "rseg" && $0.value == "12.5" })
        #expect(params.contains { $0.name == "cap_alias" && $0.value == "global_cap" })
        #expect(params.contains { $0.name == "cseg" && $0.value == "cap_alias" })
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("DSPF duplicate element IDs are made deterministic and reported in metadata")
    func duplicateElementIDsAreRenamedDeterministically() throws {
        let ir = try parse("""
        .subckt top Y VSS
        R1 Y:1 Y:2 1
        R1 Y:2 Y:3 2
        C1 Y:3 0 1f
        .ends top
        """)

        #expect(ir.elements.map(\.id) == ["C1", "R1", "R1#2"])
        #expect(ir.metadata["dspf.renamedElementID.count"] == "1")

        let renames = try decodeMetadata([DSPFElementRenameMetadata].self, from: ir, key: "dspf.renamedElementIDs")
        #expect(renames == [DSPFElementRenameMetadata(sourceID: "R1", irID: "R1#2", occurrence: 2, subckt: "top")])
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("DSPF child subckt parasitics expand into deterministic parent instance nodes")
    func childSubcktParasiticsExpandIntoParentInstanceNodes() throws {
        let ir = try parse("""
        .subckt rcchild A B
        *|S nint 7.0 8.0
        Rchild A nint rchild
        Cchild nint 0 cchild
        .ends rcchild
        .subckt top IN OUT
        .param rchild=4 cchild=2f
        Rtop OUT:1 OUT:2 1
        XU1 IN OUT rcchild
        .ends top
        """)

        #expect(ir.metadata["dspf.topSubckt"] == "top")
        #expect(ir.metadata["dspf.hierarchyExpansion.count"] == "1")
        #expect(Set(ir.elements.map(\.id)) == ["Rtop", "XU1/Rchild", "XU1/Cchild"])

        let expandedResistor = try #require(ir.elements.first { $0.id == "XU1/Rchild" })
        #expect(expandedResistor.nodeA.nodeName.value == "IN")
        #expect(expandedResistor.nodeB?.nodeName.value == "XU1/nint")
        #expect(abs(expandedResistor.value - 4.0) < 1e-9)

        let expandedCapacitor = try #require(ir.elements.first { $0.id == "XU1/Cchild" })
        #expect(expandedCapacitor.nodeA.nodeName.value == "XU1/nint")
        #expect(expandedCapacitor.nodeB == nil)
        #expect(abs(expandedCapacitor.value - 2e-15) < 1e-21)

        let internalNode = try #require(ir.nets.flatMap(\.nodes).first { $0.name.value == "XU1/nint" })
        #expect(internalNode.instancePath?.value == "XU1")
        #expect(internalNode.coordinate == Point2D(x: 7.0, y: 8.0))
        #expect(ir.metadata["dspf.annotation.subnode.count"] == "1")
        #expect(ir.metadata["dspf.effectiveAnnotation.subnode.count"] == "1")

        let sourceAnnotations = try decodeMetadata([DSPFAnnotationMetadata].self, from: ir, key: "dspf.sourceAnnotations")
        let effectiveAnnotations = try decodeMetadata([DSPFAnnotationMetadata].self, from: ir, key: "dspf.effectiveAnnotations")
        #expect(sourceAnnotations.first { $0.kind == "S" }?.target == "nint")
        #expect(effectiveAnnotations.first { $0.kind == "S" }?.target == "XU1/nint")

        let expansions = try decodeMetadata([DSPFHierarchyExpansionMetadata].self, from: ir, key: "dspf.hierarchyExpansions")
        #expect(expansions == [
            DSPFHierarchyExpansionMetadata(
                instancePath: "XU1",
                parentSubckt: "top",
                childSubckt: "rcchild",
                portBindings: [
                    DSPFPortBindingMetadata(port: "A", node: "IN"),
                    DSPFPortBindingMetadata(port: "B", node: "OUT"),
                ],
                elementCount: 2
            ),
        ])
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("DSPF effective annotations preserve nested hierarchy and port-bound node suffixes")
    func effectiveAnnotationsPreserveNestedHierarchyAndPortBoundNodeSuffixes() throws {
        let ir = try parse("""
        .subckt leaf G D
        *|P G I 1.0 2.0
        *|S G:1 3.0 4.0
        *|S nint 5.0 6.0
        *|I MCORE mos 7.0 8.0 R0
        Rleaf G:1 nint 1
        Cleaf nint D 2f
        .ends leaf
        .subckt mid M Z
        X2 M Z leaf
        .ends mid
        .subckt top IN OUT
        Rtop IN:1 IN:2 1
        X1 IN OUT mid
        .ends top
        """)

        #expect(ir.metadata["dspf.annotation.count"] == "4")
        #expect(ir.metadata["dspf.effectiveAnnotation.count"] == "4")

        let sourceAnnotations = try decodeMetadata([DSPFAnnotationMetadata].self, from: ir, key: "dspf.sourceAnnotations")
        let effectiveAnnotations = try decodeMetadata([DSPFAnnotationMetadata].self, from: ir, key: "dspf.effectiveAnnotations")
        #expect(Set(sourceAnnotations.compactMap(\.target)) == ["G", "G:1", "nint", "MCORE"])
        #expect(Set(effectiveAnnotations.compactMap(\.target)) == ["IN", "IN:1", "X1/X2/nint", "X1/X2/MCORE"])

        let inputNode = try #require(ir.nets.flatMap(\.nodes).first { $0.name.value == "IN:1" })
        #expect(inputNode.kind == .pin)
        #expect(inputNode.coordinate == Point2D(x: 3.0, y: 4.0))

        let internalNode = try #require(ir.nets.flatMap(\.nodes).first { $0.name.value == "X1/X2/nint" })
        #expect(internalNode.instancePath?.value == "X1/X2")
        #expect(internalNode.coordinate == Point2D(x: 5.0, y: 6.0))
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }

    @Test("DSPF unresolved child instances are retained as audit metadata")
    func unresolvedChildInstancesAreRetainedAsMetadata() throws {
        let ir = try parse("""
        .subckt top IN OUT
        Rtop OUT:1 OUT:2 1
        XU1 IN OUT missing_child
        .ends top
        """)

        #expect(Set(ir.elements.map(\.id)) == ["Rtop"])
        #expect(ir.metadata["dspf.unresolvedInstance.count"] == "1")

        let unresolved = try decodeMetadata([DSPFUnresolvedInstanceMetadata].self, from: ir, key: "dspf.unresolvedInstances")
        #expect(unresolved == [
            DSPFUnresolvedInstanceMetadata(
                id: "XU1",
                instancePath: "XU1",
                parentSubckt: "top",
                reason: "no_known_subckt_token",
                lineNumber: 3,
                sourceLine: "XU1 IN OUT missing_child"
            ),
        ])
        #expect(ParasiticIRValidator().validate(ir).isValid)
    }
}

private func removeTemporaryItem(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
    }
}

private func decodeMetadata<T: Decodable>(_ type: T.Type, from ir: ParasiticIR, key: String) throws -> T {
    let value = try #require(ir.metadata[key])
    let data = try #require(value.data(using: .utf8))
    return try JSONDecoder().decode(type, from: data)
}

private struct DSPFSubcktMetadata: Decodable {
    let name: String
    let elementCount: Int
}

private struct DSPFAnnotationMetadata: Decodable {
    let kind: String
    let target: String?
    let coordinate: DSPFCoordinateMetadata?
}

private struct DSPFCoordinateMetadata: Decodable, Equatable {
    let x: Double
    let y: Double
}

private struct DSPFParameterMetadata: Decodable {
    let name: String
    let value: String
}

private struct DSPFElementRenameMetadata: Decodable, Equatable {
    let sourceID: String
    let irID: String
    let occurrence: Int
    let subckt: String?
}

private struct DSPFHierarchyExpansionMetadata: Decodable, Equatable {
    let instancePath: String
    let parentSubckt: String
    let childSubckt: String
    let portBindings: [DSPFPortBindingMetadata]
    let elementCount: Int
}

private struct DSPFPortBindingMetadata: Decodable, Equatable {
    let port: String
    let node: String
}

private struct DSPFUnresolvedInstanceMetadata: Decodable, Equatable {
    let id: String
    let instancePath: String
    let parentSubckt: String
    let reason: String
    let lineNumber: Int
    let sourceLine: String
}
