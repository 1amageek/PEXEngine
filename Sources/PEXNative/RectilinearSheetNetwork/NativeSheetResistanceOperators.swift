/// Dimensionless finite-volume operators; no material geometry is synthesized.
enum NativeSheetResistanceOperators {
    static func sharedFace(sheetOhms: Double, normalSpanA: Int64, normalSpanB: Int64,
                           faceLength: Int64) throws(NativeSheetResistanceError) -> Double {
        let ratio = Double(normalSpanA + normalSpanB) / (2 * Double(faceLength))
        return try positive(sheetOhms * ratio)
    }
    static func positive(_ value: Double) throws(NativeSheetResistanceError) -> Double {
        guard value.isFinite, value > 0 else { throw .numericFailure }
        return value
    }
}
