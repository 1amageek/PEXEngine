import Foundation
import CircuiteFoundation
import CircuiteFoundationFoundation
import Testing
@testable import PEXCore

@Suite("PEX Electrical Model Tests")
struct PEXElectricalModelTests {
    private let range = PEXDimensionRangeMeters(minimumMeters: 1e-9, maximumMeters: 1e-3)

    private func fixture() throws -> TechnologyIR {
        let artifact = try ArtifactID(digest: ContentDigest(algorithm: .sha256,
                       hexadecimalValue: String(repeating: "ab", count: 32)), byteCount: 17)
        func metal(_ name: String, _ height: Double) -> PEXConductorElectricalModel {
            PEXConductorElectricalModel(layerName: name, bottomHeightMeters: height, thicknessMeters: 1e-6,
                resistivityOhmMeters: 2e-8, groundAreaFaradsPerSquareMeter: 1e-4,
                groundPerimeterFaradsPerMeter: 1e-10, widthRange: range, lengthRange: range)
        }
        let model = PEXElectricalModel(law: .analyticalRectilinearV1, coplanarScreening: nil, processName: "analytical-fixture",
            cornerID: PEXCornerID("tt"), temperatureKelvin: 298.15, voltageVolts: 1.8, parameters: [:],
            referenceNodeName: "0", calibrationArtifacts: [artifact], conductors: [metal("M1", 0), metal("M2", 2e-6)],
            vias: [PEXViaElectricalModel(viaName: "V1", cutLayerName: "C1", bottomLayerName: "M1", topLayerName: "M2",
                resistanceOhmsPerCut: 2, cutWidthRange: range, cutHeightRange: range)],
            couplings: [("M1", "M1"), ("M1", "M2"), ("M2", "M2")].map {
                PEXCouplingElectricalModel(firstLayerName: $0.0, secondLayerName: $0.1,
                    areaFaradsPerSquareMeter: 1e-5, sidewallFarads: 1e-16, gapRange: range)
            })
        return TechnologyIR(processName: "analytical-fixture",
            stack: [("M1", 0), ("C1", 1), ("M2", 2)].map {
                TechnologyLayer(name: $0.0, order: $0.1, material: nil)
            }, logicalToPhysicalLayerMap: ["metal1": "M1", "metal2": "M2"],
            vias: [TechnologyVia(name: "V1", topLayer: "M2", bottomLayer: "M1")],
            defaultExtractionRules: .default, backendHints: [:], electricalModels: [model])
    }

    // Synthetic identities exercise admission; they do not qualify a foundry process.
    private func changed(_ edit: (inout [String: Any]) -> Void) throws -> TechnologyIR {
        let data = try JSONEncoder().encode(fixture())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        edit(&object)
        return try JSONDecoder().decode(TechnologyIR.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func changedModel(_ edit: (inout [String: Any]) -> Void) throws -> TechnologyIR {
        try changed { object in
            var models = object["electricalModels"] as! [[String: Any]]
            edit(&models[0])
            object["electricalModels"] = models
        }
    }

    @Test func explicitSIModelRoundTripsAndSelectsExactPVT() throws {
        let original = try fixture()
        let decoded = try JSONDecoder().decode(TechnologyIR.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        let model = try decoded.electricalModel(for: PEXCorner(id: PEXCornerID("tt"), name: "typical",
                                                temperature: 25, voltage: 1.8))
        #expect(abs(try model.conductors[0].sheetResistanceOhms() - 0.02) < 1e-15)
        #expect(model.referenceNodeName == "0")
        #expect(TechnologyIRValidator().validate(decoded).isEmpty)
    }

    @Test func legacyMetadataCannotSupplyMissingNativeModel() throws {
        let technology = try changed { $0.removeValue(forKey: "electricalModels") }
        #expect(throws: PEXElectricalModelError.missing(field: "electricalModels.tt")) {
            try technology.electricalModel(for: PEXCorner(id: "tt"))
        }
    }

    @Test func missingCornerNeverSelectsAnotherCorner() throws {
        #expect(throws: PEXElectricalModelError.missing(field: "electricalModels.ss")) {
            try fixture().electricalModel(for: PEXCorner(id: "ss"))
        }
    }

    @Test(arguments: [-40.0, 125.0, Double.infinity, Double.nan])
    func requestedTemperatureMismatchFails(_ temperature: Double) throws {
        #expect(throws: PEXElectricalModelError.cornerMismatch(field: "temperatureKelvin")) {
            try fixture().electricalModel(for: PEXCorner(id: PEXCornerID("tt"), name: "tt", temperature: temperature))
        }
    }

    @Test func voltageAndParameterMismatchFail() throws {
        #expect(throws: PEXElectricalModelError.cornerMismatch(field: "voltageVolts")) {
            try fixture().electricalModel(for: PEXCorner(id: PEXCornerID("tt"), name: "tt", voltage: 1.2))
        }
        #expect(throws: PEXElectricalModelError.cornerMismatch(field: "parameters")) {
            try fixture().electricalModel(for: PEXCorner(id: PEXCornerID("tt"), name: "tt", parameters: ["rc": "worst"]))
        }
    }

    @Test(arguments: [0.0, -1.0, Double.infinity, Double.nan, Double.leastNonzeroMagnitude])
    func invalidAndOverflowingSheetResistanceFails(_ thickness: Double) throws {
        let layer = PEXConductorElectricalModel(layerName: "M1", bottomHeightMeters: 0, thicknessMeters: thickness,
            resistivityOhmMeters: 1, groundAreaFaradsPerSquareMeter: 0, groundPerimeterFaradsPerMeter: 0,
            widthRange: range, lengthRange: range)
        #expect(throws: PEXElectricalModelError.self) { try layer.sheetResistanceOhms() }
    }

    @Test func applicabilityIncludesOnlyDeclaredClosedInterval() throws {
        try range.requireContains(1e-9, field: "width")
        try range.requireContains(1e-3, field: "width")
        for value in [0, 1e-10, 1e-2, Double.nan, Double.infinity] {
            #expect(throws: PEXElectricalModelError.outOfRange(field: "width")) {
                try range.requireContains(value, field: "width")
            }
        }
        #expect(throws: PEXElectricalModelError.invalidRange(field: "width")) {
            try PEXDimensionRangeMeters(minimumMeters: 2, maximumMeters: 1).requireContains(1, field: "width")
        }
    }

    @Test func processAndDuplicateCornerFailAdmission() throws {
        let wrongProcess = try changedModel { $0["processName"] = "other-process" }
        #expect(throws: PEXElectricalModelError.invalidIdentity(field: "processName")) {
            try wrongProcess.validateElectricalModels()
        }
        let duplicate = try changed { object in
            let models = object["electricalModels"] as! [[String: Any]]
            object["electricalModels"] = models + models
        }
        #expect(throws: PEXElectricalModelError.duplicate(field: "electricalModels.cornerID")) {
            try duplicate.validateElectricalModels()
        }
    }

    @Test func calibrationEvidenceIsRequiredAndMustBeDistinctContent() throws {
        let missing = try changedModel { $0["calibrationArtifacts"] = [] }
        #expect(throws: PEXElectricalModelError.missing(field: "calibrationArtifacts")) {
            try missing.validateElectricalModels()
        }
        let duplicate = try changedModel { model in
            let artifacts = model["calibrationArtifacts"] as! [Any]
            model["calibrationArtifacts"] = artifacts + artifacts
        }
        #expect(throws: PEXElectricalModelError.duplicate(field: "calibrationArtifacts")) {
            try duplicate.validateElectricalModels()
        }
        let emptyArtifact = try changedModel { model in
            var artifacts = model["calibrationArtifacts"] as! [String]
            artifacts[0] = String(artifacts[0].dropLast(16)) + String(repeating: "0", count: 16)
            model["calibrationArtifacts"] = artifacts
        }
        #expect(throws: PEXElectricalModelError.invalidIdentity(field: "calibrationArtifacts")) {
            try emptyArtifact.validateElectricalModels()
        }
    }

    @Test func unknownAndIncompleteConductorRolesFail() throws {
        let missing = try changedModel { model in
            model["conductors"] = Array((model["conductors"] as! [[String: Any]]).prefix(1))
        }
        #expect(throws: PEXElectricalModelError.self) { try missing.validateElectricalModels() }
        let unknown = try changedModel { model in
            var layers = model["conductors"] as! [[String: Any]]
            layers[0]["layerName"] = "unknown"
            model["conductors"] = layers
        }
        #expect(throws: PEXElectricalModelError.invalidTopology(field: "unknown")) {
            try unknown.validateElectricalModels()
        }
    }

    @Test func swappedAndMissingCutModelsFail() throws {
        let swapped = try changedModel { model in
            var vias = model["vias"] as! [[String: Any]]
            vias[0]["bottomLayerName"] = "M2"
            vias[0]["topLayerName"] = "M1"
            model["vias"] = vias
        }
        #expect(throws: PEXElectricalModelError.invalidTopology(field: "V1")) { try swapped.validateElectricalModels() }
        let missing = try changedModel { $0["vias"] = [] }
        #expect(throws: PEXElectricalModelError.missing(field: "vias")) { try missing.validateElectricalModels() }
    }

    @Test func unorderedCouplingPairsMustBeCompleteAndUnique() throws {
        let missing = try changedModel { model in
            model["couplings"] = Array((model["couplings"] as! [[String: Any]]).prefix(2))
        }
        #expect(throws: PEXElectricalModelError.missing(field: "couplings")) { try missing.validateElectricalModels() }
        let duplicate = try changedModel { model in
            var pairs = model["couplings"] as! [[String: Any]]
            pairs.append(["firstLayerName": "M2", "secondLayerName": "M1", "areaFaradsPerSquareMeter": 0,
                          "sidewallFarads": 0, "gapRange": ["minimumMeters": 1e-9, "maximumMeters": 1e-3]])
            model["couplings"] = pairs
        }
        #expect(throws: PEXElectricalModelError.duplicate(field: "coupling.layers")) { try duplicate.validateElectricalModels() }
    }

    @Test func physicalStackGapMustBeInsideCalibrationDomain() throws {
        let technology = try changedModel { model in
            var pairs = model["couplings"] as! [[String: Any]]
            pairs[1]["gapRange"] = ["minimumMeters": 1e-8, "maximumMeters": 1e-7]
            model["couplings"] = pairs
        }
        #expect(throws: PEXElectricalModelError.outOfRange(field: "coupling.verticalGapMeters")) {
            try technology.validateElectricalModels()
        }
    }

    @Test func invalidModelIsVisibleToExistingTechnologyValidator() throws {
        let technology = try changedModel { $0["voltageVolts"] = -1 }
        #expect(TechnologyIRValidator().validate(technology).contains { $0.code == "electrical_model_invalid" })
    }

    @Test(arguments: ["bottomHeightMeters", "thicknessMeters", "resistivityOhmMeters",
                      "groundAreaFaradsPerSquareMeter", "groundPerimeterFaradsPerMeter"])
    func negativeConductorCoefficientsFail(_ field: String) throws {
        let technology = try changedModel { model in
            var layers = model["conductors"] as! [[String: Any]]
            layers[0][field] = -1
            model["conductors"] = layers
        }
        #expect(throws: PEXElectricalModelError.invalidNumber(field: "M1.\(field)")) {
            try technology.validateElectricalModels()
        }
    }

    @Test func reversedPhysicalHeightFailsEvenWithCorrectLayerNames() throws {
        let technology = try changedModel { model in
            var layers = model["conductors"] as! [[String: Any]]
            layers[1]["bottomHeightMeters"] = 0
            model["conductors"] = layers
        }
        #expect(throws: PEXElectricalModelError.invalidTopology(field: "conductor.heightOrder")) {
            try technology.validateElectricalModels()
        }
    }

    @Test func unrepresentablePositiveThicknessCannotCollapsePhysicalHeight() throws {
        let technology = try changedModel { model in
            var layers = model["conductors"] as! [[String: Any]]
            layers[0]["bottomHeightMeters"] = Double.greatestFiniteMagnitude
            model["conductors"] = layers
        }
        #expect(throws: PEXElectricalModelError.invalidNumber(field: "M1.topHeightMeters")) {
            try technology.validateElectricalModels()
        }
    }

    @Test func declaredZeroCapacitanceIsDistinctFromMissingCoefficient() throws {
        let zero = try changedModel { model in
            var pairs = model["couplings"] as! [[String: Any]]
            pairs[0]["areaFaradsPerSquareMeter"] = 0
            pairs[0]["sidewallFarads"] = 0
            model["couplings"] = pairs
        }
        try zero.validateElectricalModels()
        #expect(throws: DecodingError.self) {
            try changedModel { model in
                var pairs = model["couplings"] as! [[String: Any]]
                pairs[0].removeValue(forKey: "sidewallFarads")
                model["couplings"] = pairs
            }
        }
    }

    @Test func unknownModelLawCannotDecodeAsSupported() throws {
        #expect(throws: DecodingError.self) { try changedModel { $0["law"] = "unqualifiedLaw" } }
    }

    @Test func removedImplicitLawSpellingCannotDecode() throws {
        #expect(throws: DecodingError.self) { try changedModel { $0["law"] = "rectilinearSheetV1" } }
    }

    private func screenedFixture() throws -> TechnologyIR {
        try changed { object in
            object["stack"] = [["name": "M1", "order": 0]]
            object["logicalToPhysicalLayerMap"] = [String: String]()
            object["vias"] = [[String: Any]]()
            var model = (object["electricalModels"] as! [[String: Any]])[0]
            model["law"] = "singlePlaneCoplanarGroundV1"
            model["coplanarScreening"] = ["offsetMeters": 0.25e-6,
                "interactionHaloMeters": 8e-6, "groundFringeInverseMeters": 515_600]
            model["conductors"] = Array((model["conductors"] as! [[String: Any]]).prefix(1))
            model["vias"] = [[String: Any]]()
            var pair = (model["couplings"] as! [[String: Any]])[0]
            pair["areaFaradsPerSquareMeter"] = 0
            model["couplings"] = [pair]
            object["electricalModels"] = [model]
        }
    }

    @Test func screenedModelRoundTripsOnlyWithExplicitRequiredParameters() throws {
        let technology = try screenedFixture()
        try technology.validateElectricalModels()
        #expect(try JSONDecoder().decode(TechnologyIR.self, from: JSONEncoder().encode(technology)) == technology)
        let model = try technology.electricalModel(for: .init(id: "tt"))
        #expect(model.coplanarScreening?.groundFringeInverseMeters == 515_600)
        let missing = try changedModel { $0["law"] = "singlePlaneCoplanarGroundV1" }
        #expect(throws: PEXElectricalModelError.missing(field: "coplanarScreening")) { try missing.validateElectricalModels() }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PEXCoplanarScreening.self, from: Data("{\"offsetMeters\":0,\"interactionHaloMeters\":1}".utf8))
        }
    }

    @Test func explicitAnalyticalLawRejectsScreeningAndScreenedLawRejectsLayeredTopology() throws {
        let parameters: [String: Double] = ["offsetMeters": 0.25e-6,
            "interactionHaloMeters": 8e-6, "groundFringeInverseMeters": 515_600]
        let analytical = try changedModel { $0["coplanarScreening"] = parameters }
        #expect(throws: PEXElectricalModelError.unsupportedLawScope(field: "analyticalRectilinearV1.coplanarScreening")) {
            try analytical.validateElectricalModels()
        }
        let layered = try changedModel {
            $0["law"] = "singlePlaneCoplanarGroundV1"; $0["coplanarScreening"] = parameters
        }
        #expect(throws: PEXElectricalModelError.unsupportedLawScope(field: "singlePlaneCoplanarGroundV1.topology")) {
            try layered.validateElectricalModels()
        }
    }

    @Test(arguments: [-1.0, Double.infinity, Double.nan])
    func screeningSIParametersRejectInvalidValues(_ value: Double) throws {
        #expect(throws: PEXElectricalModelError.invalidNumber(field: "coplanarScreening.offsetMeters")) {
            try PEXCoplanarScreening(offsetMeters: value, interactionHaloMeters: 8e-6, groundFringeInverseMeters: 515_600).validate()
        }
        #expect(throws: PEXElectricalModelError.invalidNumber(field: "coplanarScreening.groundFringeInverseMeters")) {
            try PEXCoplanarScreening(offsetMeters: 0, interactionHaloMeters: 8e-6, groundFringeInverseMeters: value).validate()
        }
        #expect(throws: PEXElectricalModelError.invalidNumber(field: "coplanarScreening.interactionHaloMeters")) {
            try PEXCoplanarScreening(offsetMeters: 0, interactionHaloMeters: value, groundFringeInverseMeters: 0).validate()
        }
    }

    @Test func haloMustBePositiveButZeroOffsetAndMultiplierAreExplicitlyValid() throws {
        try PEXCoplanarScreening(offsetMeters: 0, interactionHaloMeters: 8e-6, groundFringeInverseMeters: 0).validate()
        #expect(throws: PEXElectricalModelError.invalidNumber(field: "coplanarScreening.interactionHaloMeters")) {
            try PEXCoplanarScreening(offsetMeters: 0, interactionHaloMeters: 0, groundFringeInverseMeters: 0).validate()
        }
    }

    @Test func numericalDomainIdentityNormalizesUnorderedCollectionsAndPairOrientation() throws {
        let original = try fixture().electricalModel(for: .init(id: "tt"))
        let reordered = try changedModel { model in
            model["conductors"] = Array((model["conductors"] as! [[String: Any]]).reversed())
            model["vias"] = Array((model["vias"] as! [[String: Any]]).reversed())
            model["calibrationArtifacts"] = Array((model["calibrationArtifacts"] as! [String]).reversed())
            model["couplings"] = (model["couplings"] as! [[String: Any]]).reversed().map { pair in
                var pair = pair
                let first = pair["firstLayerName"]
                pair["firstLayerName"] = pair["secondLayerName"]; pair["secondLayerName"] = first
                return pair
            }
        }.electricalModel(for: .init(id: "tt"))
        #expect(try original.domainDigest() == reordered.domainDigest())
        #expect(try original.domainDigest().algorithm == .sha256)
        for field in ["processName", "referenceNodeName"] {
            let changed = try changedModel { $0[field] = "different" }.electricalModels![0]
            #expect(try changed.domainDigest() != original.domainDigest())
        }
    }

    @Test func numericalDomainIdentityIncludesEachScreeningParameterAndLaw() throws {
        let model = try screenedFixture().electricalModel(for: .init(id: "tt"))
        let original = try model.domainDigest()
        for field in ["offsetMeters", "interactionHaloMeters", "groundFringeInverseMeters"] {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
            var screening = object["coplanarScreening"] as! [String: Double]
            screening[field] = screening[field]! * 2
            object["coplanarScreening"] = screening
            let changed = try JSONDecoder().decode(PEXElectricalModel.self,
                from: JSONSerialization.data(withJSONObject: object))
            #expect(try changed.domainDigest() != original)
        }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        object["law"] = "analyticalRectilinearV1"; object.removeValue(forKey: "coplanarScreening")
        let analytical = try JSONDecoder().decode(PEXElectricalModel.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(try analytical.domainDigest() != original)
    }

    @Test(arguments: ["thickness", "resistivity"])
    func removedAmbiguousLayerFieldsCannotDecode(_ field: String) throws {
        #expect(throws: DecodingError.self) {
            try changed { object in
                var layers = object["stack"] as! [[String: Any]]
                layers[0][field] = 1
                object["stack"] = layers
            }
        }
    }

    @Test(arguments: [false, true])
    func removedAggregateViaResistanceCannotDecode(nullValue: Bool) throws {
        #expect(throws: DecodingError.self) {
            try changed { object in
                var vias = object["vias"] as! [[String: Any]]
                vias[0]["resistance"] = nullValue ? NSNull() : 1
                object["vias"] = vias
            }
        }
    }

    @Test func invalidCutResistanceCannotBecomeIdealConnection() throws {
        let technology = try changedModel { model in
            var vias = model["vias"] as! [[String: Any]]
            vias[0]["resistanceOhmsPerCut"] = 0
            model["vias"] = vias
        }
        #expect(throws: PEXElectricalModelError.invalidNumber(field: "V1.resistanceOhmsPerCut")) {
            try technology.validateElectricalModels()
        }
    }

    @Test func unknownLayerMappingFailsNativeAdmission() throws {
        let technology = try changed { $0["logicalToPhysicalLayerMap"] = ["metal1": "missing"] }
        #expect(throws: PEXElectricalModelError.invalidTopology(field: "layerMap.metal1")) {
            try technology.validateElectricalModels()
        }
    }

    @Test func coefficientAndCalibrationIdentityChangeRequestHash() throws {
        func hash(_ technology: TechnologyIR) throws -> PEXRequestHash {
            let request = PEXRunRequest(layoutURL: URL(filePath: "/layout.gds"), layoutFormat: .gds,
                sourceNetlistURL: URL(filePath: "/netlist.sp"), sourceNetlistFormat: .spice, topCell: "TOP",
                corners: [PEXCorner(id: "tt")], technology: .inline(technology), backendSelection: .mock(), options: .default)
            return try PEXRequestHash.compute(for: request, inputArtifacts: [])
        }
        let original = try hash(fixture())
        let coefficient = try changedModel { model in
            var layers = model["conductors"] as! [[String: Any]]
            layers[0]["resistivityOhmMeters"] = 3e-8
            model["conductors"] = layers
        }
        #expect(try hash(coefficient) != original)
        let evidence = try changedModel { model in
            // ArtifactID's canonical content identity encodes its byte count.
            var artifacts = model["calibrationArtifacts"] as! [String]
            let last = artifacts[0].removeLast()
            artifacts[0].append(last == "1" ? "2" : "1")
            model["calibrationArtifacts"] = artifacts
        }
        #expect(try hash(evidence) != original)
    }
}
