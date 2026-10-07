import Foundation
import PEXCore
import PEXNative
import LayoutCore
import LayoutVerify

/// Physical-to-canonical observations. Numeric operators are retained in the canonical IR.
public struct NativePEXTopologyEvidence: Sendable, Codable {
    /// Retained process-evidence filename used to identify the typed topology record.
    public static let artifactFileName = "native-topology.json"
    public struct Net: Sendable, Codable {
        public let occurrenceIndex: Int
        public let netID: UUID
    }
    public struct Step: Sendable, Codable {
        public let instanceID: UUID
        public let row: Int
        public let column: Int
    }
    public struct Occurrence: Sendable, Codable {
        public let sourceCellID: UUID
        public let parentIndex: Int?
        public let path: [Step]
        public let transforms: [LayoutTransform]
    }
    public struct Footprint: Sendable, Codable {
        public let occurrenceIndex: Int
        public let sourceKind: String
        public let sourceIndex: Int
        public let sourceID: UUID
        public let layer: LayoutLayerID
        public let isCut: Bool
        public let bounds: [Int32]
        public let polygonIndex: Int
        public let declaredNet: Net?
    }
    public struct Component: Sendable, Codable {
        public let footprintIndices: [Int]
        public let declaredNets: [Net]
        public let pinIndices: [Int]
    }
    public struct Pin: Sendable, Codable {
        public let occurrenceIndex: Int
        public let sourcePinIndex: Int
        public let componentIndices: [Int]
        public let declaredNet: Net?
    }
    public struct Open: Sendable, Codable {
        public let net: Net
        public let componentIndices: [Int]
        public let unconnectedPinIndices: [Int]
    }
    public struct NumericNode: Sendable, Codable {
        public let reference: NodeRef
        public let kind: String
        public let layerName: String
        public let componentIndex: Int
        public let bounds: [Int32]
        public let heightMeters: Double
    }
    public struct Port: Sendable, Codable {
        public let pinIndex: Int
        public let terminal: NodeRef
        public let componentIndex: Int?
    }
    public struct Contact: Sendable, Codable {
        public let elementID: String
        public let portIndex: Int
        public let nodeIndex: Int
        public let face: NativePEXElectrodeFace
        public let ohms: Double
    }
    public let version: Int
    public let electricalContext: LayoutElectricalContext
    public let policy: NativePEXBackendPolicy
    public let image: NativePEXCodeImage
    public let executionIdentity: PEXBackendExecutionIdentity
    public let coordinateUnits: LayoutUnits
    public let model: PEXElectricalModel
    public let netBindings: [NativePEXNetBinding]
    public let occurrences: [Occurrence]
    public let footprints: [Footprint]
    public let components: [Component]
    public let pins: [Pin]
    public let opens: [Open]
    public let shortComponentIndices: [Int]
    public let numericNodes: [NumericNode]
    public let ports: [Port]
    public let electrodeContacts: [Contact]
    /// Ordered like the retained native sheet/cut resistors and ground/coupling capacitors.
    public let numericResistorElementIDs: [String]
    public let numericCapacitorElementIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case version, electricalContext, policy, image, executionIdentity, coordinateUnits, model, netBindings, occurrences, footprints, components, pins, opens, shortComponentIndices, numericNodes, ports, electrodeContacts, numericResistorElementIDs, numericCapacitorElementIDs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == 3 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c,
                debugDescription: "Native topology requires electrical-context schema version 3.")
        }
        electricalContext = try c.decode(LayoutElectricalContext.self, forKey: .electricalContext)
        policy = try c.decode(NativePEXBackendPolicy.self, forKey: .policy)
        image = try c.decode(NativePEXCodeImage.self, forKey: .image)
        executionIdentity = try c.decode(PEXBackendExecutionIdentity.self, forKey: .executionIdentity)
        coordinateUnits = try c.decode(LayoutUnits.self, forKey: .coordinateUnits)
        model = try c.decode(PEXElectricalModel.self, forKey: .model)
        netBindings = try c.decode([NativePEXNetBinding].self, forKey: .netBindings)
        occurrences = try c.decode([Occurrence].self, forKey: .occurrences)
        footprints = try c.decode([Footprint].self, forKey: .footprints)
        components = try c.decode([Component].self, forKey: .components)
        pins = try c.decode([Pin].self, forKey: .pins)
        opens = try c.decode([Open].self, forKey: .opens)
        shortComponentIndices = try c.decode([Int].self, forKey: .shortComponentIndices)
        numericNodes = try c.decode([NumericNode].self, forKey: .numericNodes)
        ports = try c.decode([Port].self, forKey: .ports)
        electrodeContacts = try c.decode([Contact].self, forKey: .electrodeContacts)
        numericResistorElementIDs = try c.decode([String].self, forKey: .numericResistorElementIDs)
        numericCapacitorElementIDs = try c.decode([String].self, forKey: .numericCapacitorElementIDs)
    }

    init(projection: NativePEXProjection, image: NativePEXCodeImage, identity: PEXBackendExecutionIdentity, policy: NativePEXBackendPolicy) {
        let electrodes = projection.electrodes, network = electrodes.network, snapshot = network.snapshot
        func net(_ occurrence: Int, _ id: UUID) -> Net { .init(occurrenceIndex: occurrence, netID: id) }
        version = 3; electricalContext = snapshot.electricalContext; self.policy = policy; self.image = image; executionIdentity = identity
        coordinateUnits = snapshot.coordinateUnits; model = network.model; netBindings = projection.netBindings
        occurrences = snapshot.hierarchy.occurrences.map { value in
            .init(sourceCellID: value.sourceCellID, parentIndex: value.parentIndex,
                path: value.path.map { .init(instanceID: $0.instanceID, row: $0.row, column: $0.column) }, transforms: value.transforms)
        }
        footprints = snapshot.footprints.map { value in
            let kind: String, index: Int
            switch value.source { case .shape(let i): kind = "shape"; index = i
                case .via(let i): kind = "via"; index = i; case .pin(let i): kind = "pin"; index = i }
            return .init(occurrenceIndex: value.occurrenceIndex, sourceKind: kind, sourceIndex: index,
                sourceID: value.sourceID, layer: value.layer, isCut: value.isCut,
                bounds: [value.band.minX, value.band.maxX, value.band.minY, value.band.maxY], polygonIndex: value.band.polygonIndex,
                declaredNet: value.declaredNet.map { net($0.occurrenceIndex, $0.netID) })
        }
        components = snapshot.components.map { .init(footprintIndices: $0.footprintIndices,
            declaredNets: $0.declaredNets.map { net($0.occurrenceIndex, $0.netID) }, pinIndices: $0.pinIndices) }
        pins = snapshot.pins.map { .init(occurrenceIndex: $0.occurrenceIndex, sourcePinIndex: $0.sourcePinIndex,
            componentIndices: $0.componentIndices, declaredNet: $0.declaredNet.map { net($0.occurrenceIndex, $0.netID) }) }
        opens = snapshot.opens.map { .init(net: net($0.net.occurrenceIndex, $0.net.netID), componentIndices: $0.componentIndices,
            unconnectedPinIndices: $0.unconnectedPinIndices) }
        shortComponentIndices = snapshot.shortComponentIndices
        numericNodes = network.nodes.enumerated().map { index, node in
            let kind: String
            switch node.kind { case .metal: kind = "metal"; case .cut(let via): kind = "cut:\(via)" }
            return .init(reference: projection.numericNodeReferences[index], kind: kind, layerName: node.layerName,
                componentIndex: node.componentIndex,
                bounds: [node.minXDatabaseUnits, node.maxXDatabaseUnits, node.minYDatabaseUnits, node.maxYDatabaseUnits], heightMeters: node.heightMeters)
        }
        ports = electrodes.ports.map { .init(pinIndex: $0.pinIndex, terminal: $0.terminal, componentIndex: $0.componentIndex) }
        electrodeContacts = electrodes.contacts.enumerated().map { .init(elementID: projection.electrodeContactElementIDs[$0.offset],
            portIndex: $0.element.portIndex, nodeIndex: $0.element.nodeIndex, face: $0.element.face, ohms: $0.element.ohms) }
        numericResistorElementIDs = projection.numericResistorElementIDs
        numericCapacitorElementIDs = projection.numericCapacitorElementIDs
    }
}
