import LayoutCore

public protocol NativePEXInputPreparing: Sendable {
    func prepare(document: LayoutDocument, topCell: String, configuration: NativePEXConfiguration,
                 isCancelled: () -> Bool) throws -> NativePEXPreparedInput
}
