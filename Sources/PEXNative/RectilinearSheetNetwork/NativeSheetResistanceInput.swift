import PEXCore

/// Source resistance facts and explicit contact-area boundary conditions over one checked union.
public struct NativeSheetResistanceInput: Sendable {
    public struct Material: Sendable, Equatable {
        public let layerName: String
        public let sheetOhms: Double
        public init(layerName: String, sheetOhms: Double) {
            self.layerName = layerName; self.sheetOhms = sheetOhms
        }
    }
    public struct Cut: Sendable, Equatable {
        public let sourceID: String
        public let netName: NetName
        public let lowerLayerName: String
        public let upperLayerName: String
        public let rect: NativeConductorUnion.Rect
        public let sourceOhms: Double
        public init(sourceID: String, netName: NetName, lowerLayerName: String, upperLayerName: String,
                    rect: NativeConductorUnion.Rect, sourceOhms: Double) {
            self.sourceID = sourceID; self.netName = netName
            self.lowerLayerName = lowerLayerName; self.upperLayerName = upperLayerName
            self.rect = rect; self.sourceOhms = sourceOhms
        }
    }
    public struct Contact: Sendable, Equatable {
        public let layerName: String
        public let rect: NativeConductorUnion.Rect
        public init(layerName: String, rect: NativeConductorUnion.Rect) {
            self.layerName = layerName; self.rect = rect
        }
    }
    public struct Terminal: Sendable, Equatable {
        public let ref: NodeRef
        public let contacts: [Contact]
        public init(ref: NodeRef, contacts: [Contact]) { self.ref = ref; self.contacts = contacts }
    }
    public let conductorUnion: NativeConductorUnion
    public let materials: [Material]
    public let cuts: [Cut]
    public let terminals: [Terminal]
    public init(conductorUnion: NativeConductorUnion, materials: [Material], cuts: [Cut], terminals: [Terminal]) {
        self.conductorUnion = conductorUnion; self.materials = materials
        self.cuts = cuts; self.terminals = terminals
    }
}
