/// Raw file output is parsed; canonical in-process output is consumed directly.
public enum PEXBackendOutput: Sendable, Codable, Hashable {
    case raw(PEXRawOutput)
    case canonical(ParasiticIR)

    public var rawOutput: PEXRawOutput? {
        switch self { case .raw(let output): output; case .canonical: nil }
    }
}
