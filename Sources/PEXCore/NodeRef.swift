public struct NodeRef: Sendable, Codable, Hashable {
    public let netName: NetName
    public let nodeName: NodeName

    public init(netName: NetName, nodeName: NodeName) {
        self.netName = netName
        self.nodeName = nodeName
    }
}
