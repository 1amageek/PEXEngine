public protocol NativePEXElectrodeBuilding: Sendable {
    func build(network: NativePEXNetwork, bindings: [NativePEXElectrodeBinding],
               limits: NativePEXElectrodeLimits, isCancelled: () -> Bool)
        throws(NativePEXElectrodeError) -> NativePEXElectrodeNetwork
}
