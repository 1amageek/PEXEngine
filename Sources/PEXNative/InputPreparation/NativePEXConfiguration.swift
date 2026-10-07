import Foundation
import LayoutCore
import LayoutTech
import LayoutVerify
import PEXCore

public struct NativePEXConfiguration: Sendable, Equatable, Codable {
    public let version: Int
    public let electricalContext: LayoutElectricalContext
    public let layoutTechnology: LayoutTechDatabase
    public let layers: [NativePEXLayerBinding]
    public let supplementalPins: [NativePEXPinDefinition]
    public let netBindings: [NativePEXInputNetBinding]
    public let electrodeBindings: [NativePEXElectrodeBinding]
    public let expectedCoordinateUnits: LayoutUnits
    public let maximumCellSpanDatabaseUnits: Int32
    public let maximumMetadataEntries: Int
    public let captureLimits: NativePEXCaptureLimits
    public let calculationLimits: NativePEXCalculationLimits
    public let electrodeLimits: NativePEXElectrodeLimits
    public let projectionLimits: NativePEXProjectionLimits
    let metadataEntriesUsed: Int

    public init(version: Int = 3, layoutTechnology: LayoutTechDatabase, layers: [NativePEXLayerBinding],
                supplementalPins: [NativePEXPinDefinition], netBindings: [NativePEXInputNetBinding],
                electrodeBindings: [NativePEXElectrodeBinding], expectedCoordinateUnits: LayoutUnits,
                maximumCellSpanDatabaseUnits: Int32, maximumMetadataEntries: Int = 1_000_000,
                captureLimits: NativePEXCaptureLimits = .init(), calculationLimits: NativePEXCalculationLimits = .default,
                electrodeLimits: NativePEXElectrodeLimits = .default, projectionLimits: NativePEXProjectionLimits = .default, electricalContext: LayoutElectricalContext = .geometric)
        throws(NativePEXInputError) {
        guard version == 3 else { throw .invalidField("version") }
        guard maximumCellSpanDatabaseUnits > 0 else { throw .invalidField("maximumCellSpanDatabaseUnits") }
        guard expectedCoordinateUnits.scale.databaseUnitsPerMicrometer.isFinite,
              expectedCoordinateUnits.scale.databaseUnitsPerMicrometer > 0,
              layoutTechnology.grid.isFinite, layoutTechnology.grid > 0 else { throw .invalidField("units/grid") }
        let lowerLimits = captureLimits.values + [calculationLimits.maximumInputRecords, calculationLimits.maximumCoordinateValues,
            calculationLimits.maximumMeshCells, calculationLimits.maximumNetworkElements, calculationLimits.maximumWorkVisits,
            calculationLimits.maximumPinContacts, electrodeLimits.maximumInputRecords, electrodeLimits.maximumFaceRecords,
            electrodeLimits.maximumContacts, electrodeLimits.maximumWorkVisits, projectionLimits.maximumInputRecords,
            projectionLimits.maximumNodes, projectionLimits.maximumElements, projectionLimits.maximumWorkVisits]
        guard lowerLimits.allSatisfy({ $0 >= 0 }) else { throw .invalidField("lowerLimits") }
        var budget = try NativePEXInputBudget(maximumMetadataEntries)
        for count in [layoutTechnology.layers.count, layers.count, supplementalPins.count, netBindings.count, electrodeBindings.count] {
            try budget.charge(count)
        }
        var known = Set<LayoutLayerID>(), standardPairs = Set<String>()
        for layer in layoutTechnology.layers {
            try budget.identifier(layer.id.name, field: "technology.layer.name")
            try budget.identifier(layer.id.purpose, field: "technology.layer.purpose")
            guard layer.gdsLayer >= 0, layer.gdsDatatype >= 0,
                  known.insert(layer.id).inserted,
                  standardPairs.insert("\(layer.gdsLayer):\(layer.gdsDatatype)").inserted else {
                throw .invalidField("technology.layerMapping")
            }
        }
        if case .deviceAwareMOSAndPolyResistors(let poly, let marker) = electricalContext {
            for id in [poly, marker] {
                try budget.identifier(id.name, field: "electricalContext.layer.name")
                try budget.identifier(id.purpose, field: "electricalContext.layer.purpose")
                guard known.contains(id) else { throw .invalidField("electricalContext.layers") }
            }
            guard poly != marker else { throw .invalidField("electricalContext.layers") }
        }
        guard !layers.isEmpty else { throw .invalidField("layers") }
        var bound = Set<LayoutLayerID>(), names = Set<String>(), conductive = Set<LayoutLayerID>()
        for binding in layers {
            try budget.identifier(binding.layerID.name, field: "layer.id.name")
            try budget.identifier(binding.layerID.purpose, field: "layer.id.purpose")
            try budget.identifier(binding.electricalName, field: "layer.electricalName")
            guard known.contains(binding.layerID), bound.insert(binding.layerID).inserted,
                  names.insert(binding.electricalName).inserted else { throw .invalidField("layers") }
            if binding.isConductive { conductive.insert(binding.layerID) }
        }
        guard !conductive.isEmpty else { throw .invalidField("conductiveLayers") }
        var pinIDs: [String: Set<UUID>] = [:], pinNames: [String: Set<String>] = [:]
        var supplementalNets: [String: Set<UUID>] = [:]
        for definition in supplementalPins {
            try budget.identifier(definition.cellName, field: "pin.cellName")
            try budget.identifier(definition.pin.name, field: "pin.name")
            let pin = definition.pin
            guard conductive.contains(pin.layer), pin.position.x.isFinite, pin.position.y.isFinite,
                  pin.size.width.isFinite, pin.size.height.isFinite, pin.size.width > 0, pin.size.height > 0,
                  (pin.position.x - pin.size.width / 2).isFinite, (pin.position.x + pin.size.width / 2).isFinite,
                  (pin.position.y - pin.size.height / 2).isFinite, (pin.position.y + pin.size.height / 2).isFinite,
                  pin.position.x - pin.size.width / 2 < pin.position.x + pin.size.width / 2,
                  pin.position.y - pin.size.height / 2 < pin.position.y + pin.size.height / 2,
                  pinIDs[definition.cellName, default: []].insert(pin.id).inserted,
                  pinNames[definition.cellName, default: []].insert(pin.name).inserted else { throw .invalidField("supplementalPins") }
            if let netID = pin.netID { supplementalNets[definition.cellName, default: []].insert(netID) }
        }
        var selectors = Set<NativePEXInputNetSelector>(), sourceNetNames = Set<String>()
        for binding in netBindings {
            try budget.identifier(binding.netName.value, field: "net.name")
            try budget.identifier(binding.selector.expectedCellName, field: "net.expectedCellName")
            switch binding.selector {
            case .sourceDeclared(_, _, let name):
                try budget.identifier(name, field: "net.sourceNetName")
            case .supplemental(_, let cell, let id):
                guard supplementalNets[cell]?.contains(id) == true else {
                    throw .undeclaredSupplementalNet(cell: cell, netID: id)
                }
            }
            guard binding.selector.occurrenceIndex >= 0,
                  selectors.insert(binding.selector).inserted,
                  sourceNetNames.insert(binding.netName.value).inserted else { throw .invalidField("netBindings") }
        }
        var pinIndices = Set<Int>(), terminals = Set<NodeRef>()
        for binding in electrodeBindings {
            try budget.identifier(binding.terminal.netName.value, field: "terminal.net")
            try budget.identifier(binding.terminal.nodeName.value, field: "terminal.node")
            try budget.charge(binding.faces.count)
            guard binding.pinIndex >= 0, pinIndices.insert(binding.pinIndex).inserted,
                  terminals.insert(binding.terminal).inserted,
                  binding.faces.allSatisfy({ $0.begin < $0.end }) else { throw .invalidField("electrodeBindings") }
        }
        self.version = version; self.electricalContext = electricalContext; self.layoutTechnology = layoutTechnology; self.layers = layers
        self.supplementalPins = supplementalPins; self.netBindings = netBindings; self.electrodeBindings = electrodeBindings
        self.expectedCoordinateUnits = expectedCoordinateUnits; self.maximumCellSpanDatabaseUnits = maximumCellSpanDatabaseUnits
        self.maximumMetadataEntries = maximumMetadataEntries; self.captureLimits = captureLimits
        self.calculationLimits = calculationLimits; self.electrodeLimits = electrodeLimits; self.projectionLimits = projectionLimits
        self.metadataEntriesUsed = maximumMetadataEntries - budget.remaining
    }

    public var layerNames: [LayoutLayerID: String] { Dictionary(uniqueKeysWithValues: layers.map { ($0.layerID, $0.electricalName) }) }
    public var conductiveLayers: Set<LayoutLayerID> { Set(layers.filter(\.isConductive).map(\.layerID)) }

    private enum CodingKeys: String, CodingKey {
        case version, electricalContext, layoutTechnology, layers, supplementalPins, netBindings, electrodeBindings
        case expectedCoordinateUnits, maximumCellSpanDatabaseUnits, maximumMetadataEntries
        case captureLimits, calculationLimits, electrodeLimits, projectionLimits
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        guard version == 3 else { throw NativePEXInputError.invalidField("version") }
        try self.init(version: version, layoutTechnology: c.decode(LayoutTechDatabase.self, forKey: .layoutTechnology),
            layers: c.decode([NativePEXLayerBinding].self, forKey: .layers), supplementalPins: c.decode([NativePEXPinDefinition].self, forKey: .supplementalPins),
            netBindings: c.decode([NativePEXInputNetBinding].self, forKey: .netBindings), electrodeBindings: c.decode([NativePEXElectrodeBinding].self, forKey: .electrodeBindings),
            expectedCoordinateUnits: c.decode(LayoutUnits.self, forKey: .expectedCoordinateUnits), maximumCellSpanDatabaseUnits: c.decode(Int32.self, forKey: .maximumCellSpanDatabaseUnits),
            maximumMetadataEntries: c.decode(Int.self, forKey: .maximumMetadataEntries), captureLimits: c.decode(NativePEXCaptureLimits.self, forKey: .captureLimits),
            calculationLimits: c.decode(NativePEXCalculationLimits.self, forKey: .calculationLimits), electrodeLimits: c.decode(NativePEXElectrodeLimits.self, forKey: .electrodeLimits),
            projectionLimits: c.decode(NativePEXProjectionLimits.self, forKey: .projectionLimits),
            electricalContext: c.decode(LayoutElectricalContext.self, forKey: .electricalContext))
    }
}
