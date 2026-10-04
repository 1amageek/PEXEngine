public enum PEXBackendResultError: Error, Sendable, Equatable {
    case missingRawFiles
    case nonlocalRawFile
    case canonicalRequiresInProcessInvocation
    case noncanonicalUnits
    case invalidCanonicalIR([ParasiticIRValidationError])
}
