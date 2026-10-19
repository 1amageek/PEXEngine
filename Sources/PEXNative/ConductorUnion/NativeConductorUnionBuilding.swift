public protocol NativeConductorUnionBuilding: Sendable {
    func build(sources: [NativeConductorUnion.Source], databaseUnitsPerMicron: Int64,
               limits: NativeConductorUnionLimits, isCancelled: @Sendable () -> Bool)
        throws(NativeConductorError) -> NativeConductorUnion
}
