public struct PEXAdapterExecutionResult: Sendable, Codable, Hashable {
    public let output: PEXBackendOutput
    public let generatedArtifacts: [PEXGeneratedArtifact]
    public let physicalTopology: PEXPhysicalTopology?
    public let executionIdentity: PEXBackendExecutionIdentity
    /// Derived admission evidence for canonical output; raw output is validated after parsing.
    public let canonicalValidationWarnings: [ParasiticIRValidationWarning]

    public init(output: PEXBackendOutput, generatedArtifacts: [PEXGeneratedArtifact],
                executionIdentity: PEXBackendExecutionIdentity, physicalTopology: PEXPhysicalTopology? = nil) throws(PEXBackendResultError) {
        switch output {
        case .raw(let raw):
            guard !raw.fileURLs.isEmpty else { throw .missingRawFiles }
            guard raw.fileURLs.allSatisfy(\.isFileURL) else { throw .nonlocalRawFile }
            self.canonicalValidationWarnings = []
        case .canonical(let ir):
            guard executionIdentity.invocation.mode == .inProcess else { throw .canonicalRequiresInProcessInvocation }
            guard ir.units == .canonical else { throw .noncanonicalUnits }
            let validation = ParasiticIRValidator().validate(ir)
            guard validation.isValid else { throw .invalidCanonicalIR(validation.errors) }
            self.canonicalValidationWarnings = validation.warnings
        }
        self.physicalTopology = physicalTopology
        self.output = output; self.generatedArtifacts = generatedArtifacts; self.executionIdentity = executionIdentity
    }

    private enum CodingKeys: String, CodingKey { case output, generatedArtifacts, executionIdentity, physicalTopology }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(output: container.decode(PEXBackendOutput.self, forKey: .output),
                      generatedArtifacts: container.decode([PEXGeneratedArtifact].self, forKey: .generatedArtifacts),
                      executionIdentity: container.decode(PEXBackendExecutionIdentity.self, forKey: .executionIdentity),
                      physicalTopology: container.decodeIfPresent(PEXPhysicalTopology.self, forKey: .physicalTopology))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.output == rhs.output && lhs.generatedArtifacts == rhs.generatedArtifacts && lhs.executionIdentity == rhs.executionIdentity && lhs.physicalTopology == rhs.physicalTopology
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(output); hasher.combine(generatedArtifacts); hasher.combine(executionIdentity); hasher.combine(physicalTopology)
    }
}
