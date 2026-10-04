import Foundation
import CircuiteFoundation
import PEXCore
import LayoutCore
import LayoutTech
import LayoutVerify
@testable import PEXNative

struct NativePEXTestFixture {
    var m1: LayoutLayerID { .init(name: "M1", purpose: "drawing") }
    var m2: LayoutLayerID { .init(name: "M2", purpose: "drawing") }
    var cut: LayoutLayerID { .init(name: "VIA1", purpose: "cut") }
    var bindings: [LayoutLayerID: String] { [m1: "M1", m2: "M2", cut: "C1"] }
    func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> LayoutShape {
        LayoutShape(layer: m1, geometry: .rect(.init(origin: .init(x: x, y: y), size: .init(width: width, height: height))))
    }
    func technology() throws -> TechnologyIR {
        let range = PEXDimensionRangeMeters(minimumMeters: 1e-12, maximumMeters: 1)
        let artifact = try ArtifactID(digest: ContentDigest(algorithm: .sha256,
                        hexadecimalValue: String(repeating: "ac", count: 32)), byteCount: 17)
        let model = PEXElectricalModel(law: .rectilinearSheetV1, processName: "analytic",
            cornerID: "tt", temperatureKelvin: 298.15, voltageVolts: 1.8, parameters: [:], referenceNodeName: "0",
            calibrationArtifacts: [artifact], conductors: [0.0, 2e-6].enumerated().map {
                PEXConductorElectricalModel(layerName: "M\($0.offset + 1)", bottomHeightMeters: $0.element,
                    thicknessMeters: 1e-6, resistivityOhmMeters: 2e-8, groundAreaFaradsPerSquareMeter: 1e-4,
                    groundPerimeterFaradsPerMeter: 1e-10, widthRange: range, lengthRange: range)
            }, vias: [PEXViaElectricalModel(viaName: "VIA1", cutLayerName: "C1", bottomLayerName: "M1",
                topLayerName: "M2", resistanceOhmsPerCut: 2, cutWidthRange: range, cutHeightRange: range)],
            couplings: [("M1", "M1"), ("M1", "M2"), ("M2", "M2")].map {
                PEXCouplingElectricalModel(firstLayerName: $0.0, secondLayerName: $0.1,
                    areaFaradsPerSquareMeter: 1e-5, sidewallFarads: 1e-16, gapRange: range)
            })
        return TechnologyIR(processName: "analytic", stack: [("M1", 0), ("C1", 1), ("M2", 2)].map {
            TechnologyLayer(name: $0.0, order: $0.1)
        }, logicalToPhysicalLayerMap: [:], vias: [TechnologyVia(name: "VIA1", topLayer: "M2", bottomLayer: "M1")],
            defaultExtractionRules: .default, backendHints: [:], electricalModels: [model])
    }
    func snapshot(_ cell: LayoutCell, children: [LayoutCell] = [],
                  scale: DatabaseUnitScale = .nanometerGrid, tech: LayoutTechDatabase = .standard(),
                  conductiveLayers: Set<LayoutLayerID>? = nil) throws -> LayoutConductorSnapshot {
        let document = LayoutDocument(name: "native", units: LayoutUnits(scale: scale),
                                      cells: [cell] + children, topCellID: cell.id)
        return try LayoutConnectivityExtractor().captureConductors(document: document, tech: tech,
                                                                   conductiveLayers: conductiveLayers ?? [m1, m2])
    }
    func mesh(_ cell: LayoutCell, span: Int32 = 1_000,
                      limits: NativePEXCalculationLimits = .default) throws -> NativePEXMesh {
        try NativePEXMesh.build(snapshot: snapshot(cell), technology: technology(), corner: PEXCorner(id: "tt"),
            layerNames: bindings, maximumCellSpanDatabaseUnits: span, limits: limits)
    }
    func area(_ mesh: NativePEXMesh) -> Double {
        mesh.orderedKeys.reduce(0) { sum, key in
            sum + Double(Int64(mesh.x[key.x + 1]) - Int64(mesh.x[key.x]))
                * Double(Int64(mesh.y[key.y + 1]) - Int64(mesh.y[key.y]))
                * mesh.metersPerDatabaseUnit * mesh.metersPerDatabaseUnit
        }
    }

}
