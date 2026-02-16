public struct ParasiticNode: Sendable, Codable, Hashable {
    public let name: NodeName
    public let kind: NodeKind
    public let instancePath: InstancePath?
    public let coordinate: Point2D?

    public init(name: NodeName, kind: NodeKind, instancePath: InstancePath?, coordinate: Point2D?) {
        self.name = name
        self.kind = kind
        self.instancePath = instancePath
        self.coordinate = coordinate
    }
}
