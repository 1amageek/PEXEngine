import CircuiteFoundation

public extension PEXRunRequest {
    /// Returns the Foundation hierarchy identity for the requested top cell.
    func designObjectReference() throws -> DesignObjectReference {
        try DesignObjectReference(kind: .cell, identifier: topCell)
    }
}
