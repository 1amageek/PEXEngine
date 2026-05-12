import Foundation

public enum SPEFResistanceUnit: String, Sendable, Hashable {
    case ohm = "OHM"
    case kiloOhm = "KOHM"
    case megaOhm = "MOHM"

    var ohmsPerUnit: Double {
        switch self {
        case .ohm: return 1.0
        case .kiloOhm: return 1e3
        case .megaOhm: return 1e6
        }
    }
}
