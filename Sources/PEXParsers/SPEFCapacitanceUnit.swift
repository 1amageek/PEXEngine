import Foundation

public enum SPEFCapacitanceUnit: String, Sendable, Hashable {
    case farad = "F"
    case nanoFarad = "NF"
    case picoFarad = "PF"
    case femtoFarad = "FF"

    var faradsPerUnit: Double {
        switch self {
        case .farad: return 1.0
        case .nanoFarad: return 1e-9
        case .picoFarad: return 1e-12
        case .femtoFarad: return 1e-15
        }
    }
}
