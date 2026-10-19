import CircuiteFoundation
import PEXCore

/// Source-bound integer geometry. Constructing this value does not admit its facts.
public struct NativeRoutedPEXInput: Sendable, Codable, Hashable {
    public enum Axis: String, Sendable, Codable, Hashable { case horizontal, vertical }
    public enum Role: String, Sendable, Codable, Hashable { case signal, reference }
    public enum OriginDerivation: String, Sendable, Codable, Hashable {
        case firstDEFTrackMinusHalfDefaultWidth, dieLowerLeft
    }
    public struct SourceFact: Sendable, Codable, Hashable {
        public let artifactID: ArtifactID
        public let byteRange: PEXOpenRCXSourceModel.SourceRange
        public init(artifactID: ArtifactID, byteRange: PEXOpenRCXSourceModel.SourceRange) {
            self.artifactID = artifactID; self.byteRange = byteRange
        }
    }
    public struct Rect: Sendable, Codable, Hashable {
        public let minX: Int64, minY: Int64, maxX: Int64, maxY: Int64
        public init(minX: Int64, minY: Int64, maxX: Int64, maxY: Int64) {
            self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
        }
    }
    public struct Layer: Sendable, Codable, Hashable {
        public let name: String
        public let level: Int
        public let preferredDirection: Axis
        public let pitchDatabaseUnits: Int64
        public let defaultWidthDatabaseUnits: Int64
        public let sheetResistanceOhmsPerSquare: Double
        public let searchOriginX: Int64, searchOriginY: Int64
        public let originDerivationX: OriginDerivation, originDerivationY: OriginDerivation
        public let firstDEFTrackX: Int64?, firstDEFTrackY: Int64?
        public let sourceFacts: [SourceFact]
        public init(name: String, level: Int, preferredDirection: Axis, pitchDatabaseUnits: Int64,
                    defaultWidthDatabaseUnits: Int64, sheetResistanceOhmsPerSquare: Double,
                    searchOriginX: Int64, searchOriginY: Int64,
                    originDerivationX: OriginDerivation, originDerivationY: OriginDerivation,
                    firstDEFTrackX: Int64? = nil, firstDEFTrackY: Int64? = nil, sourceFacts: [SourceFact]) {
            self.name = name; self.level = level; self.preferredDirection = preferredDirection
            self.pitchDatabaseUnits = pitchDatabaseUnits; self.defaultWidthDatabaseUnits = defaultWidthDatabaseUnits
            self.sheetResistanceOhmsPerSquare = sheetResistanceOhmsPerSquare
            self.searchOriginX = searchOriginX; self.searchOriginY = searchOriginY
            self.originDerivationX = originDerivationX; self.originDerivationY = originDerivationY
            self.firstDEFTrackX = firstDEFTrackX; self.firstDEFTrackY = firstDEFTrackY
            self.sourceFacts = sourceFacts
        }
    }
    public struct Net: Sendable, Codable, Hashable {
        public let name: NetName
        public let role: Role
        public let sourceFacts: [SourceFact]
        public init(name: NetName, role: Role, sourceFacts: [SourceFact]) {
            self.name = name; self.role = role; self.sourceFacts = sourceFacts
        }
    }
    public struct Node: Sendable, Codable, Hashable {
        public let ref: NodeRef
        public let layerName: String
        public let x: Int64, y: Int64
        public let sourceFacts: [SourceFact]
        public init(ref: NodeRef, layerName: String, x: Int64, y: Int64, sourceFacts: [SourceFact]) {
            self.ref = ref; self.layerName = layerName; self.x = x; self.y = y; self.sourceFacts = sourceFacts
        }
    }
    public struct Wire: Sendable, Codable, Hashable {
        public let sourceID: String
        public let sourceOrdinal: Int
        public let netName: NetName
        public let layerName: String
        public let axis: Axis
        public let rect: Rect
        public let sourceNode: NodeRef, targetNode: NodeRef
        public let sourceFacts: [SourceFact]
        public init(sourceID: String, sourceOrdinal: Int, netName: NetName, layerName: String,
                    axis: Axis, rect: Rect, sourceNode: NodeRef, targetNode: NodeRef, sourceFacts: [SourceFact]) {
            self.sourceID = sourceID; self.sourceOrdinal = sourceOrdinal; self.netName = netName
            self.layerName = layerName; self.axis = axis; self.rect = rect
            self.sourceNode = sourceNode; self.targetNode = targetNode; self.sourceFacts = sourceFacts
        }
    }
    public struct Landing: Sendable, Codable, Hashable {
        public let layerName: String
        public let rect: Rect
        public let sourceFacts: [SourceFact]
        public init(layerName: String, rect: Rect, sourceFacts: [SourceFact]) {
            self.layerName = layerName; self.rect = rect; self.sourceFacts = sourceFacts
        }
    }
    public struct Cut: Sendable, Codable, Hashable {
        public let layerName: String
        public let rect: Rect
        public let resistanceOhms: Double
        public let sourceFacts: [SourceFact]
        public init(layerName: String, rect: Rect, resistanceOhms: Double, sourceFacts: [SourceFact]) {
            self.layerName = layerName; self.rect = rect; self.resistanceOhms = resistanceOhms; self.sourceFacts = sourceFacts
        }
    }
    public struct Via: Sendable, Codable, Hashable {
        public let sourceID: String
        public let sourceOrdinal: Int
        public let netName: NetName
        public let sourceNode: NodeRef, targetNode: NodeRef
        public let cuts: [Cut]
        public let landings: [Landing]
        public let sourceFacts: [SourceFact]
        public init(sourceID: String, sourceOrdinal: Int, netName: NetName, sourceNode: NodeRef,
                    targetNode: NodeRef, cuts: [Cut], landings: [Landing], sourceFacts: [SourceFact]) {
            self.sourceID = sourceID; self.sourceOrdinal = sourceOrdinal; self.netName = netName
            self.sourceNode = sourceNode; self.targetNode = targetNode
            self.cuts = cuts; self.landings = landings; self.sourceFacts = sourceFacts
        }
    }
    public struct Terminal: Sendable, Codable, Hashable {
        public let ref: NodeRef
        public let instancePath: InstancePath?
        public let contacts: [Landing]
        public let sourceFacts: [SourceFact]
        public init(ref: NodeRef, instancePath: InstancePath? = nil, contacts: [Landing], sourceFacts: [SourceFact]) {
            self.ref = ref; self.instancePath = instancePath; self.contacts = contacts; self.sourceFacts = sourceFacts
        }
    }
    public let selection: PEXOpenRCXSourceModel.Selection
    public let defArtifactID: ArtifactID
    public let sourceArtifacts: [ArtifactID]
    public let databaseUnitsPerMicron: Int64
    public let dieBounds: Rect
    public let layers: [Layer]
    public let nets: [Net]
    public let nodes: [Node]
    public let wires: [Wire]
    public let vias: [Via]
    public let terminals: [Terminal]
    public init(selection: PEXOpenRCXSourceModel.Selection, defArtifactID: ArtifactID, sourceArtifacts: [ArtifactID],
                databaseUnitsPerMicron: Int64, dieBounds: Rect, layers: [Layer], nets: [Net], nodes: [Node],
                wires: [Wire], vias: [Via], terminals: [Terminal]) {
        self.selection = selection; self.defArtifactID = defArtifactID; self.sourceArtifacts = sourceArtifacts
        self.databaseUnitsPerMicron = databaseUnitsPerMicron; self.dieBounds = dieBounds
        self.layers = layers; self.nets = nets; self.nodes = nodes
        self.wires = wires; self.vias = vias; self.terminals = terminals
    }
}
