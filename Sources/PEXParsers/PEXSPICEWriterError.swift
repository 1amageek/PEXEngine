import Foundation

public enum PEXSPICEWriterError: Error, Sendable, Equatable, LocalizedError {
    case invalidNodeName(String)
    case nodeIdentityCollision(String)
    case invalidElementIdentifier(String)
    case nonFiniteValue(String)
    case negativeValue(String)
    case missingEndpoint(String)

    public var errorDescription: String? {
        switch self {
        case .invalidNodeName(let value):
            return "SPICE node name is empty or contains whitespace/control characters: \(value)"
        case .nodeIdentityCollision(let value):
            return "SPICE node identity collision while lowering PEX node: \(value)"
        case .invalidElementIdentifier(let value):
            return "SPICE element identifier is empty or cannot be represented: \(value)"
        case .nonFiniteValue(let id):
            return "PEX element '\(id)' has a non-finite value"
        case .negativeValue(let id):
            return "PEX element '\(id)' has a negative value"
        case .missingEndpoint(let id):
            return "PEX element '\(id)' requires a second node endpoint"
        }
    }
}
