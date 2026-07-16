/// Parses an extractor-native output into canonical parasitic IR.
public protocol PEXParsing: Sendable {
    var format: PEXOutputFormat { get }
    func parse(_ raw: PEXRawOutput, context: PEXParseContext) throws -> ParasiticIR
}
