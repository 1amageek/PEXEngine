public struct PEXActionDomainSnapshot: Codable, Sendable, Hashable {
    public let schemaVersion: Int
    public let domainID: String
    public let ownerPackages: [String]
    public let operations: [PEXActionDomainOperation]

    public init(
        schemaVersion: Int = 1,
        domainID: String,
        ownerPackages: [String],
        operations: [PEXActionDomainOperation]
    ) {
        self.schemaVersion = schemaVersion
        self.domainID = domainID
        self.ownerPackages = ownerPackages
        self.operations = operations
    }
}

