import Foundation
import CryptoKit
import Testing
import CircuiteFoundation
import PEXCore
import PEXNative
import PEXAdapters
import PEXRuntime
import PEXPersistence
import LayoutCore
import LayoutTech
import LayoutIO
import SignoffToolSupport

@Suite("Native and actual Magic single-plane capacitance", .timeLimit(.minutes(1)))
struct NativeMagicGroundCapacitanceCorrelationTests {
    struct Rectangle: Sendable, CustomStringConvertible {
        let length: Double
        let width: Double
        let gap: Double?
        init(length: Double, width: Double, gap: Double? = nil) {
            self.length = length; self.width = width; self.gap = gap
        }
        var description: String { "\(length)x\(width)um-gap\(gap.map(String.init(describing:)) ?? "isolated")" }
    }

    @Test(.enabled(if: MagicPEXAdapterTests.toolchain != nil), arguments: [
        Rectangle(length: 10, width: 10), Rectangle(length: 20, width: 5),
        Rectangle(length: 20, width: 10), Rectangle(length: 100, width: 1),
        Rectangle(length: 10, width: 1, gap: 1), Rectangle(length: 10, width: 1, gap: 2),
    ])
    func capturedStandardRectangleAgreesWithActualMagic(rectangle: Rectangle) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "native-magic-correlation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Failed to remove correlation workspace: \(error)") }
        }
        let toolchain = try #require(MagicPEXAdapterTests.toolchain)
        let profile = try SignoffPDKProfile.bundledDefaultProfile()
        let sourceDeck = try SignoffPDKLocator.requiredFileURL(in: toolchain.pdkRoot, profile: profile, requirementID: "magic-tech")
        let deckBytes = try Data(contentsOf: sourceDeck)
        let deckText = try #require(String(data: deckBytes, encoding: .utf8))
        let nominalCaps = try section(deckText, after: "# Nominal capacitances", before: "# Parasitic capacitance values for minimum corner")
        let nominalResistance = try section(deckText, after: "# Resistances are in milliohms per square", before: "# High-end corner resistances")
        let areaSource = try coefficient(["defaultareacap", "allm1", "metal1"], in: nominalCaps)
        let area = areaSource * 1e-6
        let perimeter = try coefficient(["defaultperimeter", "allm1", "metal1"], in: nominalCaps) * 1e-12
        let sheet = try coefficient(["resist", "(allm1)/metal1"], in: nominalResistance) * 1e-3
        let height = try coefficient(["height", "allm1"], in: deckText) * 1e-6
        let thickness = try coefficient(["height", "allm1"], in: deckText, valueIndex: 1) * 1e-6
        let calibrationID = try artifactID(deckBytes)
        let calibrationURL = root.appending(path: "calibration-sky130A.tech")
        try deckBytes.write(to: calibrationURL)
        let range = PEXDimensionRangeMeters(minimumMeters: (1e-6).nextDown, maximumMeters: (100e-6).nextUp)
        let gapRange = PEXDimensionRangeMeters(minimumMeters: 1e-6, maximumMeters: 100e-6)
        let sidewall = try coefficient(["defaultsidewall", "allm1", "metal1"], in: nominalCaps) * 1e-18
        // Both observables use the ideal substrate; native standard output names
        // its implicit reference 0, while the installed Magic deck names it VSUBS.
        let screening = PEXCoplanarScreening(
            offsetMeters: try coefficient(["defaultsidewall", "allm1", "metal1"], in: nominalCaps, valueIndex: 1) * 1e-6,
            interactionHaloMeters: try coefficient(["sidehalo"], in: deckText) * 1e-6,
            // Magic 8.3.652 ExtTech.c FRINGE_MULT is a source-law approximation.
            // Convert its 0.02 * area(aF/um^2) inverse-micron result to inverse meters.
            groundFringeInverseMeters: 0.02 * areaSource * 1e6)
        let model = PEXElectricalModel(law: .singlePlaneCoplanarGroundV1, coplanarScreening: screening, processName: "sky130A", cornerID: "nominal",
            temperatureKelvin: 298.15, voltageVolts: 1.8, parameters: [:], referenceNodeName: "0",
            calibrationArtifacts: [calibrationID], conductors: [.init(layerName: "M1", bottomHeightMeters: height,
                thicknessMeters: thickness, resistivityOhmMeters: sheet * thickness,
                groundAreaFaradsPerSquareMeter: area, groundPerimeterFaradsPerMeter: perimeter,
                widthRange: range, lengthRange: range)], vias: [],
            couplings: [.init(firstLayerName: "M1", secondLayerName: "M1", areaFaradsPerSquareMeter: 0,
                sidewallFarads: sidewall, gapRange: gapRange)])
        let technology = TechnologyIR(processName: "sky130A", stack: [.init(name: "M1", order: 0)],
            logicalToPhysicalLayerMap: [:], vias: [], defaultExtractionRules: .default, backendHints: [:], electricalModels: [model])
        let layer = LayoutLayerID(name: "M1", purpose: "drawing")
        let layoutTechnology = LayoutTechDatabase(units: .defaultUnits, grid: 0.005,
            layers: [.init(id: layer, displayName: "Metal1", gdsLayer: 68, gdsDatatype: 20,
                color: .init(red: 0.3, green: 0.5, blue: 0.9))], vias: [], layerRules: [])
        let configuration = try NativePEXConfiguration(layoutTechnology: layoutTechnology,
            layers: [.init(layerID: layer, electricalName: "M1", isConductive: true)], supplementalPins: [],
            netBindings: [], electrodeBindings: [], expectedCoordinateUnits: .defaultUnits,
            maximumCellSpanDatabaseUnits: 1000, calculationLimits: .init(maximumMeshCells: 512))
        func strip(_ y: Double) -> LayoutShape {
            .init(layer: layer, geometry: .rect(.init(origin: .init(x: 0, y: y),
                size: .init(width: rectangle.length, height: rectangle.width))))
        }
        var shapes = [strip(0)]
        if let gap = rectangle.gap { shapes.append(strip(rectangle.width + gap)) }
        let cell = LayoutCell(name: "cap_rectangle", shapes: shapes)
        let document = LayoutDocument(name: "correlation", cells: [cell], topCellID: cell.id)
        let layoutURL = root.appending(path: "rectangle.gds")
        try MaskDataFormatConverter(tech: layoutTechnology).exportDocument(document, to: layoutURL, format: .gds)
        let layoutID = try artifactID(Data(contentsOf: layoutURL))
        let sourceURL = root.appending(path: "source.spice")
        try Data(".subckt cap_rectangle\n.ends cap_rectangle\n".utf8).write(to: sourceURL)
        let configurationURL = root.appending(path: "configuration.json")
        try JSONEncoder().encode(configuration).write(to: configurationURL)
        let nativeInput = try PEXNativeInputReference(configurationURL: configurationURL,
            calibrations: [.init(artifactID: calibrationID, url: calibrationURL)])
        func request(_ backend: String, _ mode: PEXExtractMode) -> PEXRunRequest {
            .init(layoutURL: layoutURL, layoutFormat: .gds, sourceNetlistURL: sourceURL, sourceNetlistFormat: .spice,
                topCell: "cap_rectangle", corners: [.init(id: "nominal")], technology: .inline(technology),
                nativeInput: nativeInput, processProfile: toolchain.processProfileReference,
                backendSelection: .init(backendID: backend),
                options: .init(extractMode: mode, includeCouplingCaps: true, minCapacitanceF: nil,
                    minResistanceOhm: nil, maxParallelJobs: 1, emitRawArtifacts: true, emitIRJSON: true, strictValidation: true),
                workingDirectory: root.appending(path: backend))
        }
        let engine = DefaultPEXEngine.withDefaults()
        let native = try await engine.run(request("native", .rc))
        let oracle = try await engine.run(request("magic", .cOnly))
        try #require(native.status == .success, "Native run: \(native.cornerResults)")
        try #require(oracle.status == .success, "Magic run: \(oracle.cornerResults)")
        let nativeIR = try #require(native.cornerResults.first?.ir)
        let oracleIR = try #require(oracle.cornerResults.first?.ir)
        let nativeValue = nativeIR.nets.reduce(0) { $0 + $1.totalGroundCapF }
        let oracleValue = oracleIR.nets.reduce(0) { $0 + $1.totalGroundCapF }
        let rawURL = try #require(oracle.cornerResults.first?.rawOutputURLs.first)
        let rawBytes = try Data(contentsOf: rawURL)
        let rawText = try #require(String(data: rawBytes, encoding: .utf8))
        let capacitorLines = rawText.split(whereSeparator: \.isNewline).filter { $0.first == "C" }
        try #require(capacitorLines.count == (rectangle.gap == nil ? 1 : 3))
        var printBudget = 0.0
        for capacitorLine in capacitorLines {
            let literal = try #require(capacitorLine.split(whereSeparator: \.isWhitespace).dropFirst(3).first)
            try #require(literal.hasSuffix("f"))
            let fraction = try #require(literal.dropLast().split(separator: ".", omittingEmptySubsequences: false).dropFirst().first)
            printBudget += 0.5 * pow(10.0, -Double(fraction.count)) * 1e-15
        }
        let operationCount = 4 * nativeIR.elements.count + nativeIR.nets.count
        let nativeCoupling = nativeIR.elements.filter { $0.kind == .coupling }.reduce(0) { $0 + $1.value }
        let oracleCoupling = oracleIR.elements.filter { $0.kind == .coupling }.reduce(0) { $0 + $1.value }
        let floatingBudget = Double(operationCount) * Double.ulpOfOne * abs(nativeValue + nativeCoupling)
        #expect(abs(nativeValue - oracleValue) <= printBudget + floatingBudget)
        #expect(abs(nativeCoupling - oracleCoupling) <= printBudget + floatingBudget)
        if rectangle.gap == nil {
            #expect(nativeIR.elements.allSatisfy { $0.kind != .coupling })
            #expect(oracleIR.elements.count == 1 && oracleIR.elements[0].kind == .capacitor)
        } else {
            #expect(nativeCoupling > 0 && oracleCoupling > 0)
        }
        #expect(try artifactID(Data(contentsOf: sourceDeck)) == calibrationID)
        #expect(try artifactID(Data(contentsOf: layoutURL)) == layoutID)
        let nativeIdentity = try #require(native.artifactManifest.backendExecutions.first)
        let oracleIdentity = try #require(oracle.artifactManifest.backendExecutions.first)
        #expect(nativeIdentity.invocation.mode == .inProcess && nativeIdentity.producer.identifier == "pex-native")
        #expect(oracleIdentity.invocation.mode == .externalProcess && oracleIdentity.producer.identifier == "pex-magic")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let summary = """
        geometry_um,native_ground_F,magic_ground_F,native_coupling_F,magic_coupling_F,print_budget_F,floating_budget_F,layout_sha256,calibration_sha256
        \(rectangle.description),\(nativeValue),\(oracleValue),\(nativeCoupling),\(oracleCoupling),\(printBudget),\(floatingBudget),\(layoutID.digest.hexadecimalValue),\(calibrationID.digest.hexadecimalValue)
        """
        Attachment.record(summary, named: "\(rectangle.description)-comparison.csv")
        Attachment.record(Array(deckBytes), named: "\(rectangle.description)-calibration.tech")
        for (backend, result) in [("native", native), ("magic", oracle)] {
            let store = PEXArtifactStore(workspace: .init(baseURL: root.appending(path: backend), runID: result.runID))
            let captured = try store.loadRequest()
            #expect(try artifactID(Data(contentsOf: captured.layoutURL)) == layoutID)
            Attachment.record(Array(try encoder.encode(captured)), named: "\(rectangle.description)-\(backend)-captured-request.json")
            Attachment.record(Array(try encoder.encode(result)), named: "\(rectangle.description)-\(backend)-result.json")
            Attachment.record(Array(try Data(contentsOf: captured.layoutURL)), named: "\(rectangle.description)-\(backend)-captured.gds")
            Attachment.record(Array(try Data(contentsOf: captured.sourceNetlistURL)), named: "\(rectangle.description)-\(backend)-source.spice")
            let input = try #require(captured.nativeInput)
            Attachment.record(Array(try Data(contentsOf: input.configurationURL)), named: "\(rectangle.description)-\(backend)-configuration.json")
            let calibration = try #require(input.calibrations.first)
            #expect(calibration.artifactID == calibrationID)
            #expect(try artifactID(Data(contentsOf: calibration.url)) == calibrationID)
            let resolver = try PEXArtifactResolver(manifestURL: result.manifestURL)
            for kind in [PEXArtifactKind.processProfileDeckInput, .processEvidence, .log, .rawOutput] {
                for record in resolver.records(kind: kind, availability: .available) {
                    let url = try resolver.validatedURL(for: record)
                    Attachment.record(Array(try Data(contentsOf: url)), named: "\(rectangle.description)-\(backend)-\(url.lastPathComponent)")
                }
            }
        }
    }

    private func section(_ source: String, after start: String, before end: String) throws -> String {
        let beginning = try #require(source.range(of: start))
        let remainder = source[beginning.upperBound...]
        let ending = try #require(remainder.range(of: end))
        return String(remainder[..<ending.lowerBound])
    }

    private func coefficient(_ fields: [String], in source: String, valueIndex: Int = 0) throws -> Double {
        let lines = source.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace) }
            .filter { $0.prefix(fields.count).map(String.init) == fields }
        let line = try #require(lines.count == 1 ? lines.first : nil, "Expected one source parameter: \(fields)")
        let index = fields.count + valueIndex
        try #require(line.indices.contains(index))
        return try #require(Double(line[index]))
    }

    private func artifactID(_ bytes: Data) throws -> ArtifactID {
        try .init(digest: .init(algorithm: .sha256, hexadecimalValue:
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()), byteCount: UInt64(bytes.count))
    }
}
