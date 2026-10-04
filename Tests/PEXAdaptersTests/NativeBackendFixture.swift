import Foundation
import CryptoKit
import CircuiteFoundation
import PEXCore
import PEXNative
import LayoutCore
import LayoutTech
import LayoutIO

struct NativeBackendFixture {
    let root: URL
    let request: PEXRunRequest
    let technology: TechnologyIR
    let calibrationURL: URL
    let calibrationBytes = Data("analytic-fixture".utf8)
    let runID = PEXRunID()
    var context: PEXExecutionContext { contextReplacing() }

    init(format: LayoutFileFormat, open: Bool, short: Bool, meshLimit: Int, span: Int32) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "native-backend-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        calibrationURL = root.appending(path: "calibration.bin")
        try calibrationBytes.write(to: calibrationURL)
        let calibration = try ArtifactID(digest: ContentDigest(algorithm: .sha256, hexadecimalValue:
            SHA256.hash(data: calibrationBytes).map { String(format: "%02x", $0) }.joined()), byteCount: UInt64(calibrationBytes.count))
        let range = PEXDimensionRangeMeters(minimumMeters: 1e-12, maximumMeters: 1)
        let model = PEXElectricalModel(law: .rectilinearSheetV1, processName: "analytic", cornerID: "tt",
            temperatureKelvin: 298.15, voltageVolts: 1.8, parameters: [:], referenceNodeName: "0", calibrationArtifacts: [calibration],
            conductors: [.init(layerName: "M1", bottomHeightMeters: 0, thicknessMeters: 1e-6, resistivityOhmMeters: 2e-8,
                groundAreaFaradsPerSquareMeter: 1e-4, groundPerimeterFaradsPerMeter: 1e-10, widthRange: range, lengthRange: range)],
            vias: [], couplings: [.init(firstLayerName: "M1", secondLayerName: "M1", areaFaradsPerSquareMeter: 1e-5,
                sidewallFarads: 1e-16, gapRange: range)])
        technology = .init(processName: "analytic", stack: [.init(name: "M1", order: 0)], logicalToPhysicalLayerMap: [:],
            vias: [], defaultExtractionRules: .default, backendHints: [:], electricalModels: [model])
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let netID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let otherNetID = UUID(uuidString: "00000000-0000-0000-0000-000000000456")!
        func rect(_ x: Double, _ width: Double) -> LayoutShape {
            .init(layer: layer, geometry: .rect(.init(origin: .init(x: x, y: 0), size: .init(width: width, height: 1))))
        }
        let cell = LayoutCell(name: "TOP", shapes: open ? [rect(0, 0.4), rect(0.6, 0.4)] : [rect(0, 1)])
        let document = LayoutDocument(name: "analytical", cells: [cell], topCellID: cell.id)
        let config = try NativePEXConfiguration(layoutTechnology: .standard(), layers: [.init(layerID: layer, electricalName: "M1", isConductive: true)],
            supplementalPins: ["A", "B"].enumerated().map { index, name in
                .init(cellName: "TOP", pin: .init(name: name, position: .init(x: open ? (index == 0 ? 0.2 : 0.8) : 0.5, y: 0.5),
                    size: .init(width: open ? 0.4 : 1, height: 1), layer: layer, netID: short && index == 1 ? otherNetID : netID))
            }, netBindings: [.init(occurrenceIndex: 0, netID: netID, netName: NetName("SIGNAL"))]
                + (short ? [.init(occurrenceIndex: 0, netID: otherNetID, netName: NetName("OTHER"))] : []),
            electrodeBindings: [
                .init(pinIndex: 0, terminal: .init(netName: NetName("SIGNAL"), nodeName: NodeName("A")),
                    faces: [.init(side: .minX, coordinate: 0, begin: 0, end: 1000)]),
                .init(pinIndex: 1, terminal: .init(netName: NetName(short ? "OTHER" : "SIGNAL"), nodeName: NodeName("B")),
                    faces: [.init(side: .maxX, coordinate: 1000, begin: 0, end: 1000)])],
            expectedCoordinateUnits: .defaultUnits, maximumCellSpanDatabaseUnits: span,
            calculationLimits: .init(maximumMeshCells: meshLimit))
        let layout = root.appending(path: format == .gds ? "input.gds" : "input.oas")
        try MaskDataFormatConverter(tech: config.layoutTechnology).exportDocument(document, to: layout, format: format)
        let configurationURL = root.appending(path: "configuration.json")
        try JSONEncoder().encode(config).write(to: configurationURL)
        let source = root.appending(path: "source.spice")
        try Data(".subckt TOP A B\n.ends TOP\n".utf8).write(to: source)
        request = .init(layoutURL: layout, layoutFormat: format == .gds ? .gds : .oas, sourceNetlistURL: source,
            sourceNetlistFormat: .spice, topCell: "TOP", corners: [.init(id: "tt")], technology: .inline(technology),
            nativeInput: try .init(configurationURL: configurationURL, calibrations: [.init(artifactID: calibration, url: calibrationURL)]),
            backendSelection: .init(backendID: "native"), options: .default, workingDirectory: root)
    }
    func contextReplacing(nativeInput: PEXNativeInputReference?? = nil, layoutFormat: PEXCore.LayoutFormat? = nil,
                          options: PEXRunOptions? = nil, selection: PEXBackendSelection? = nil,
                          check: PEXExecutionContext.CancellationCheck? = nil) -> PEXExecutionContext {
        .init(runID: runID, corner: .init(id: "tt"), layoutURL: request.layoutURL, layoutFormat: layoutFormat ?? request.layoutFormat,
            sourceNetlistURL: request.sourceNetlistURL, sourceNetlistFormat: .spice, topCell: "TOP", technology: technology,
            nativeInput: nativeInput ?? request.nativeInput, backendSelection: selection ?? request.backendSelection,
            options: options ?? .default, workingDirectory: root, rawOutputDirectory: root.appending(path: "direct"), cancellationCheck: check)
    }
}
