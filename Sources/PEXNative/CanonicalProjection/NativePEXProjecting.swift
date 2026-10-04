public protocol NativePEXProjecting: Sendable {
    func project(electrodes: NativePEXElectrodeNetwork, netBindings: [NativePEXNetBinding],
                 limits: NativePEXProjectionLimits, isCancelled: () -> Bool)
        throws(NativePEXProjectionError) -> NativePEXProjection
}
