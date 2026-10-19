public enum PEXBackendResultError: Error, Sendable, Equatable {
    case invalidPhysicalTopology
    case missingRawFiles
    case nonlocalRawFile
    case canonicalRequiresInProcessInvocation
    case noncanonicalUnits
    case invalidCanonicalIR([ParasiticIRValidationError])
}
