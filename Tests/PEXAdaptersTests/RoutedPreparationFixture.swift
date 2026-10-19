import Foundation
import CircuiteFoundation
import PEXCore
import PEXNative
import PEXParsers
import PEXAdapters
import PEXRuntime

struct RoutedPreparationFixture {
    let root: URL
    let defURL: URL
    let netlistURL: URL
    let routeTechURL: URL
    let fullTechURL: URL
    let cellURL: URL
    let rulesURL: URL
    let configURL: URL
    let def: ArtifactReference
    let netlist: ArtifactReference
    let routeTech: ArtifactReference
    let fullTech: ArtifactReference
    let cell: ArtifactReference
    let rules: ArtifactReference
    let corner: PEXRoutedCornerSource
    let configuration: NativeRoutedPEXConfiguration
    let additionalCalibrations: [PEXCalibrationInput]

    init(viaOnly: Bool = false, orientation: String = "N", endpointX: Int = 2300, endpointY: Int = 2400,
         defOverride: String? = nil, fullTechOverride: String? = nil,
         extraCorner: Bool = false, allCorners: Bool = false, netlistOverride: String? = nil, limits: NativeRoutedPEXPreparationLimits? = nil) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "routed-source-preparation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defURL = root.appending(path: "top.def"); netlistURL = root.appending(path: "top.v")
        routeTechURL = root.appending(path: "routed-technology.lef"); fullTechURL = root.appending(path: "full-technology.lef")
        cellURL = root.appending(path: "cells.lef"); rulesURL = root.appending(path: "rules.original"); configURL = root.appending(path: "routed.json")
        let ruleFixture = try Self.ruleFixture()
        func save(_ source: Data, at url: URL, kind: String) throws -> ArtifactReference {
            try source.write(to: url)
            return try .init(digest: .init(algorithm: .sha256, hexadecimalValue: PEXRequestHash.compute(from: source).value),
                byteCount: UInt64(source.count), descriptor: .init(role: .input, kind: ArtifactKind(rawValue: kind), format: .raw))
        }
        let route = viaOnly
            ? "+ ROUTED met1 ( 500 \(endpointY) ) ( \(endpointX) \(endpointY) ) + ROUTED li1 ( 500 \(endpointY) ) L1M1 + ROUTED li1 ( \(endpointX) \(endpointY) ) L1M1"
            : "+ ROUTED li1 ( 500 \(endpointY) ) ( \(endpointX) \(endpointY) )"
        let defSource = defOverride ?? """
        VERSION 5.8 ;
        DESIGN top ;
        UNITS DISTANCE MICRONS 1000 ;
        DIEAREA ( 0 0 ) ( 10000 10000 ) ;
        TRACKS X 230 DO 20 STEP 460 LAYER li1 ;
        COMPONENTS 1 ;
        - U2 CELL + PLACED ( 2000 2000 ) \(orientation) ;
        END COMPONENTS
        PINS 1 ;
        - input + NET signal + DIRECTION INPUT + USE SIGNAL + LAYER li1 ( -100 -100 ) ( 100 100 ) + FIXED ( 500 \(endpointY) ) N ;
        END PINS
        NETS 1 ;
        - signal ( PIN input ) ( U2 A ) \(route) ;
        END NETS
        END DESIGN
        """
        def = try save(Data(defSource.utf8), at: defURL, kind: "layout")
        let structural = netlistOverride ?? "module \\top (\\input ); input \\input ; wire \\signal ; assign \\signal = \\input ; \\CELL \\U2 (.\\A (\\signal )); endmodule\n"
        netlist = try save(Data(structural.utf8), at: netlistURL, kind: "netlist")
        routeTech = try save(Data(Self.technology(full: false).utf8), at: routeTechURL, kind: "routed-technology")
        fullTech = try save(Data((fullTechOverride ?? Self.technology(full: true)).utf8), at: fullTechURL, kind: "full-technology")
        cell = try save(Data("""
        VERSION 5.8 ;
        MACRO CELL
          CLASS CORE ;
          ORIGIN 0 0 ;
          SIZE 2 BY 1 ;
          PIN A
            DIRECTION INPUT ;
            USE SIGNAL ;
            PORT
              LAYER li1 ;
              RECT 0.2 0.3 0.4 0.5 ;
            END
          END A
        END CELL
        END LIBRARY
        """.utf8), at: cellURL, kind: "cell-library")
        rules = try save(ruleFixture, at: rulesURL, kind: "original-rc-rules")
        corner = .init(cornerID: "nominal", selection: .init(processName: "source-fixture", corner: .nominal,
            rulesArtifactID: rules.id, technologyLEFArtifactID: fullTech.id,
            routingLayerNames: ["li1", "met1", "met2", "met3", "met4", "met5"]), rules: rules, technologyLEF: fullTech)
        var corners = extraCorner ? [corner, .init(cornerID: "fast", selection: .init(processName: "source-fixture", corner: .minimum,
            rulesArtifactID: rules.id, technologyLEFArtifactID: fullTech.id, routingLayerNames: corner.selection.routingLayerNames),
            rules: rules, technologyLEF: fullTech)] : [corner]
        var additional: [PEXCalibrationInput] = []
        if allCorners {
            corners = [corner]
            for (name, rc) in [("min", PEXOpenRCXSourceModel.RCCorner.minimum), ("max", .maximum)] {
                let url = root.appending(path: "rules.\(name)")
                let reference = try save(Self.ruleFixture(name), at: url, kind: "original-rc-rules")
                additional.append(.init(artifactID: reference.id, url: url))
                corners.append(.init(cornerID: .init(name), selection: .init(processName: "source-fixture", corner: rc,
                    rulesArtifactID: reference.id, technologyLEFArtifactID: fullTech.id,
                    routingLayerNames: corner.selection.routingLayerNames), rules: reference, technologyLEF: fullTech))
            }
        }
        additionalCalibrations = additional
        configuration = .init(algorithm: .unionSheetAreaBoundaryV1, sources: .init(expectedDEF: def, expectedSourceNetlist: netlist, routedTechnologyLEF: routeTech,
            standardCellLEFs: [cell], corners: corners),
            maximumCellSpanDatabaseUnits: 1000, extractionLimits: .init(maximumInputRecords: 100000, maximumStringBytes: 1000000, maximumSourceRecords: 100000,
                maximumWorkVisits: 10000000, maximumTrackEntries: 100000, maximumCoordinateValues: 100000,
                maximumGraphNodes: 100000, maximumGraphElements: 100000, maximumQueryReceipts: 100000),
            compilationLimits: .init(maximumSourceBytes: 16000000, maximumLineBytes: 10000, maximumLines: 1000000,
                maximumRecords: 1000000, maximumRows: 1000000, maximumWorkVisits: 100000000),
            preparationLimits: limits ?? .init(maximumSourceBytes: 16000000, maximumTotalSourceBytes: 64000000,
                maximumRecords: 100000, maximumStringBytes: 1000000, maximumWorkVisits: 100000000, maximumNetlistManagedStorageBytes: 64000000, maximumNetlistAllocationBytes: 128000000))
        try JSONEncoder().encode(configuration).write(to: configURL)
    }
    func context() throws -> PEXExecutionContext {
        .init(runID: .init(), corner: .init(id: "nominal"), layoutURL: defURL, layoutFormat: .def,
            sourceNetlistURL: netlistURL, sourceNetlistFormat: .verilog, topCell: "top",
            technology: .init(processName: "source-fixture", stack: [], logicalToPhysicalLayerMap: [:], vias: [],
                defaultExtractionRules: .default, backendHints: [:]),
            nativeInput: try .init(configurationURL: configURL,
                calibrations: [.init(artifactID: routeTech.id, url: routeTechURL), .init(artifactID: fullTech.id, url: fullTechURL),
                    .init(artifactID: cell.id, url: cellURL), .init(artifactID: rules.id, url: rulesURL)] + additionalCalibrations, configurationKind: .routedOpenRCXV1),
            executionInputArtifacts: sourceReferences,
            options: .default, workingDirectory: root, rawOutputDirectory: root.appending(path: "raw"))
    }
    var sourceReferences: [ArtifactReference] {
        Array(Set([def, netlist, routeTech, cell] + configuration.sources.corners.flatMap { [$0.rules, $0.technologyLEF] }))
            .sorted { $0.id.digest.hexadecimalValue < $1.id.digest.hexadecimalValue }
    }
    func request() throws -> PEXRunRequest {
        let c = try context()
        return .init(layoutURL: c.layoutURL, layoutFormat: .def, sourceNetlistURL: c.sourceNetlistURL,
            sourceNetlistFormat: .verilog, topCell: c.topCell,
            corners: configuration.sources.corners.map { .init(id: $0.cornerID, name: $0.cornerID.value) },
            technology: .inline(c.technology), nativeInput: c.nativeInput, backendSelection: .init(backendID: "native"),
            options: .default, workingDirectory: root, executionInputArtifacts: sourceReferences)
    }
    func removeOriginals() throws {
        for url in [defURL, netlistURL, routeTechURL, fullTechURL, cellURL, rulesURL, configURL]
            + additionalCalibrations.map(\.url) {
            try FileManager.default.removeItem(at: url)
        }
    }
    func remove() throws { try FileManager.default.removeItem(at: root) }
    static func ruleFixture(_ corner: String = "nom") throws -> Data {
        guard let url = Bundle.module.url(forResource: "rules.openrcx.sky130A.\(corner).calibre", withExtension: nil, subdirectory: "OpenRCXRules") else {
            throw NativeRoutedPEXPreparationError.missingSource("Retained original rule test resource")
        }
        return try Data(contentsOf: url)
    }
    static func technology(full: Bool, resistance: String = "12.8", width: String = "0.2") -> String {
        let names = full ? ["li1", "met1", "met2", "met3", "met4", "met5"] : ["li1", "met1"]
        var source = "VERSION 5.8 ;\nUNITS\n DATABASE MICRONS 1000 ;\n CAPACITANCE PICOFARADS 1 ;\nEND UNITS\n"
        for (index, name) in names.enumerated() {
            source += """
            LAYER \(name)
              TYPE ROUTING ;
              DIRECTION \(index == 0 ? "VERTICAL" : "HORIZONTAL") ;
              PITCH \(index == 0 ? "0.46 0.34" : "0.34") ;
              WIDTH \(name == "li1" ? width : "0.2") ;
              RESISTANCE RPERSQ \(name == "li1" ? resistance : "0.125") ;
              CAPACITANCE CPERSQDIST 0.0001 ;
              EDGECAPACITANCE 0.0002 ;
              THICKNESS 0.3 ;
            END \(name)

            """
            if index == 0 { source += "LAYER mcon\n TYPE CUT ;\n WIDTH 0.1 ;\n RESISTANCE 9.3 ;\nEND mcon\n" }
        }
        source += """
        VIA L1M1 DEFAULT
          LAYER mcon ;
          RECT -0.05 -0.05 0.05 0.05 ;
          LAYER li1 ;
          RECT -0.1 -0.1 0.1 0.1 ;
          LAYER met1 ;
          RECT -0.1 -0.1 0.1 0.1 ;
        END L1M1
        END LIBRARY
        """
        return source
    }
}
