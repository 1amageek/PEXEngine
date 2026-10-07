import CircuiteFoundation
import CircuiteFoundationFoundation

public struct PEXElectricalModel: Sendable, Codable, Hashable {
    public enum Law: String, Sendable, Codable, Hashable {
        case analyticalRectilinearV1
        case singlePlaneCoplanarGroundV1
    }

    public let law: Law
    public let coplanarScreening: PEXCoplanarScreening?
    public let processName: String
    public let cornerID: PEXCornerID
    public let temperatureKelvin: Double
    public let voltageVolts: Double
    public let parameters: [String: String]
    public let referenceNodeName: String
    public let calibrationArtifacts: [ArtifactID]
    public let conductors: [PEXConductorElectricalModel]
    public let vias: [PEXViaElectricalModel]
    public let couplings: [PEXCouplingElectricalModel]

    public init(law: Law, coplanarScreening: PEXCoplanarScreening?, processName: String, cornerID: PEXCornerID, temperatureKelvin: Double,
                voltageVolts: Double, parameters: [String: String], referenceNodeName: String,
                calibrationArtifacts: [ArtifactID], conductors: [PEXConductorElectricalModel],
                vias: [PEXViaElectricalModel], couplings: [PEXCouplingElectricalModel]) {
        self.law = law
        self.coplanarScreening = coplanarScreening
        self.processName = processName
        self.cornerID = cornerID
        self.temperatureKelvin = temperatureKelvin
        self.voltageVolts = voltageVolts
        self.parameters = parameters
        self.referenceNodeName = referenceNodeName
        self.calibrationArtifacts = calibrationArtifacts
        self.conductors = conductors
        self.vias = vias
        self.couplings = couplings
    }

    public func validate(in technology: TechnologyIR) throws(PEXElectricalModelError) {
        switch law {
        case .analyticalRectilinearV1:
            guard coplanarScreening == nil else { throw .unsupportedLawScope(field: "analyticalRectilinearV1.coplanarScreening") }
        case .singlePlaneCoplanarGroundV1:
            guard let coplanarScreening else { throw .missing(field: "coplanarScreening") }
            try coplanarScreening.validate()
            guard conductors.count == 1, vias.isEmpty, technology.vias.isEmpty, technology.stack.count == 1,
                  couplings.count == 1, let conductor = conductors.first, let pair = couplings.first,
                  pair.firstLayerName == conductor.layerName, pair.secondLayerName == conductor.layerName,
                  pair.areaFaradsPerSquareMeter == 0 else {
                throw .unsupportedLawScope(field: "singlePlaneCoplanarGroundV1.topology")
            }
        }
        try ElectricalModelAdmission.identity(processName, field: "processName")
        try ElectricalModelAdmission.identity(cornerID.value, field: "cornerID")
        try ElectricalModelAdmission.identity(referenceNodeName, field: "referenceNodeName")
        guard processName == technology.processName else { throw .invalidIdentity(field: "processName") }
        try ElectricalModelAdmission.number(temperatureKelvin, field: "temperatureKelvin", positive: true)
        try ElectricalModelAdmission.number(voltageVolts, field: "voltageVolts")
        for (key, value) in parameters {
            try ElectricalModelAdmission.identity(key, field: "parameters.key")
            try ElectricalModelAdmission.identity(value, field: "parameters.\(key)")
        }
        guard !calibrationArtifacts.isEmpty else { throw .missing(field: "calibrationArtifacts") }
        var artifactIDs = Set<ArtifactID>()
        for artifact in calibrationArtifacts {
            guard artifact.byteCount > 0, artifact.digest.algorithm == .sha256 else {
                throw .invalidIdentity(field: "calibrationArtifacts")
            }
            guard artifactIDs.insert(artifact).inserted else { throw .duplicate(field: "calibrationArtifacts") }
        }
        var stack: [String: Int] = [:]
        var orders = Set<Int>()
        for layer in technology.stack {
            try ElectricalModelAdmission.identity(layer.name, field: "stack.layerName")
            guard layer.order >= 0 else { throw .invalidTopology(field: "stack.order") }
            guard stack.updateValue(layer.order, forKey: layer.name) == nil,
                  orders.insert(layer.order).inserted else { throw .duplicate(field: "stack") }
        }
        for (logical, physical) in technology.logicalToPhysicalLayerMap {
            try ElectricalModelAdmission.identity(logical, field: "layerMap.logical")
            guard stack[physical] != nil else { throw .invalidTopology(field: "layerMap.\(logical)") }
        }
        guard !conductors.isEmpty else { throw .missing(field: "conductors") }
        var metal: [String: PEXConductorElectricalModel] = [:]
        for layer in conductors {
            try layer.validate()
            guard stack[layer.layerName] != nil else { throw .invalidTopology(field: layer.layerName) }
            guard metal.updateValue(layer, forKey: layer.layerName) == nil else { throw .duplicate(field: layer.layerName) }
        }
        let ordered = technology.stack.sorted { $0.order < $1.order }.compactMap { metal[$0.name] }
        for index in ordered.indices.dropFirst() {
            let previous = ordered[index - 1]
            guard previous.bottomHeightMeters + previous.thicknessMeters < ordered[index].bottomHeightMeters else {
                throw .invalidTopology(field: "conductor.heightOrder")
            }
        }
        var declaredVias: [String: TechnologyVia] = [:]
        for via in technology.vias {
            try ElectricalModelAdmission.identity(via.name, field: "technology.viaName")
            guard declaredVias.updateValue(via, forKey: via.name) == nil else { throw .duplicate(field: via.name) }
        }
        var viaNames = Set<String>()
        var cuts = Set<String>()
        var cutTopLayers: [String: String] = [:]
        for via in vias {
            try via.validate()
            guard viaNames.insert(via.viaName).inserted else { throw .duplicate(field: via.viaName) }
            guard let declared = declaredVias[via.viaName],
                  declared.bottomLayer == via.bottomLayerName, declared.topLayer == via.topLayerName,
                  metal[via.bottomLayerName] != nil, metal[via.topLayerName] != nil,
                  metal[via.cutLayerName] == nil,
                  let bottom = stack[via.bottomLayerName], let cut = stack[via.cutLayerName],
                  let top = stack[via.topLayerName], bottom < cut, cut < top else {
                throw .invalidTopology(field: via.viaName)
            }
            // Alternative bottom materials share one physical cut/top landing.
            // Geometry-dependent unique pair admission belongs to SheetExtraction.
            if let existing = cutTopLayers[via.cutLayerName], existing != via.topLayerName {
                throw .invalidTopology(field: via.cutLayerName)
            }
            cutTopLayers[via.cutLayerName] = via.topLayerName
            cuts.insert(via.cutLayerName)
        }
        guard viaNames == Set(declaredVias.keys) else { throw .missing(field: "vias") }
        guard Set(metal.keys).union(cuts) == Set(stack.keys) else { throw .missing(field: "stack.electricalRole") }

        var pairs = Set<Set<String>>()
        for pair in couplings {
            try pair.validate()
            guard let first = metal[pair.firstLayerName], let second = metal[pair.secondLayerName] else {
                throw .invalidTopology(field: "coupling.layers")
            }
            guard pairs.insert([pair.firstLayerName, pair.secondLayerName]).inserted else {
                throw .duplicate(field: "coupling.layers")
            }
            if pair.firstLayerName != pair.secondLayerName {
                let lower = first.bottomHeightMeters < second.bottomHeightMeters ? first : second
                let upper = first.bottomHeightMeters < second.bottomHeightMeters ? second : first
                try pair.gapRange.requireContains(upper.bottomHeightMeters - lower.bottomHeightMeters - lower.thicknessMeters,
                                                  field: "coupling.verticalGapMeters")
            }
        }
        let (incremented, incrementOverflow) = conductors.count.addingReportingOverflow(1)
        let (product, multiplyOverflow) = conductors.count.multipliedReportingOverflow(by: incremented)
        guard !incrementOverflow, !multiplyOverflow, pairs.count == product / 2 else { throw .missing(field: "couplings") }
    }
}
