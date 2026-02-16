public protocol PEXParserProtocol: Sendable {
    var format: PEXOutputFormat { get }
    func parse(_ raw: PEXRawOutput, context: PEXParseContext) throws -> ParasiticIR
}
