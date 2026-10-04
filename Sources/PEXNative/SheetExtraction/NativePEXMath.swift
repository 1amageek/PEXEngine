enum NativePEXMath {
    static func positive(_ value: Double) throws(NativePEXCalculationError) -> Double {
        guard value.isFinite, value > 0 else { throw .numericFailure }
        return value
    }

    static func nonnegative(_ value: Double) throws(NativePEXCalculationError) -> Double {
        guard value.isFinite, value >= 0 else { throw .numericFailure }
        return value
    }

    static func term(coefficient: Double, geometry: Double) throws(NativePEXCalculationError) -> Double {
        if coefficient == 0 || geometry == 0 { return 0 }
        return try positive(coefficient * geometry)
    }
}
