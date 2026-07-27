import CircuiteFoundation

public extension PEXRunRequest {
    /// Returns the unresolved physical path for the requested top cell.
    func designSubjectReference() throws -> DesignSubjectReference {
        .path(
            try DesignPathReference(
                facetID: DesignFacetID(rawValue: "physical"),
                kindID: DesignEntityKindID(rawValue: "cell"),
                localIdentifier: topCell
            )
        )
    }
}
