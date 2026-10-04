import LayoutCore

public struct NativePEXLayerBinding: Sendable, Equatable, Codable {
    public let layerID: LayoutLayerID
    public let electricalName: String
    public let isConductive: Bool

    public init(layerID: LayoutLayerID, electricalName: String, isConductive: Bool) {
        self.layerID = layerID; self.electricalName = electricalName; self.isConductive = isConductive
    }
}
