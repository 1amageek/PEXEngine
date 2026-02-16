public struct ParasiticElement: Sendable, Codable, Hashable {
    public let id: String
    public let kind: ElementKind
    public let nodeA: NodeRef
    public let nodeB: NodeRef?
    public let value: Double
    public let source: ElementSource

    public init(id: String, kind: ElementKind, nodeA: NodeRef, nodeB: NodeRef?, value: Double, source: ElementSource) {
        self.id = id
        self.kind = kind
        self.nodeA = nodeA
        self.nodeB = nodeB
        self.value = value
        self.source = source
    }
}
