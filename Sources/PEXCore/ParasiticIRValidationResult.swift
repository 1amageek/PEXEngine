public struct ParasiticIRValidationResult: Sendable {
    public let errors: [ParasiticIRValidationError]
    public let warnings: [ParasiticIRValidationWarning]
    public var isValid: Bool { errors.isEmpty }

    public init(errors: [ParasiticIRValidationError] = [], warnings: [ParasiticIRValidationWarning] = []) {
        self.errors = errors
        self.warnings = warnings
    }
}
