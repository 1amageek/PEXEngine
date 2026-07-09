import Foundation
import PEXCore

public enum SPEFWriterError: Error, Sendable, LocalizedError, Equatable {
    case invalidIdentifier(String)
    case nonFiniteValue(id: String, value: Double)
    case missingResistorEndpoint(id: String)
    case missingInductorEndpoint(id: String)
    case unsupportedElementKind(id: String, kind: ElementKind)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let value):
            return "Invalid SPEF identifier '\(value)'"
        case .nonFiniteValue(let id, let value):
            return "Element '\(id)' has non-finite value \(value)"
        case .missingResistorEndpoint(let id):
            return "Resistor '\(id)' is missing its second endpoint"
        case .missingInductorEndpoint(let id):
            return "Inductor '\(id)' is missing its second endpoint"
        case .unsupportedElementKind(let id, let kind):
            return "Element '\(id)' has unsupported SPEF writer kind '\(kind.rawValue)'"
        }
    }
}
