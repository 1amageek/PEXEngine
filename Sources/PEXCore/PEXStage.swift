import Foundation

public enum PEXStage: String, Sendable, Codable, Hashable, CustomStringConvertible {
    case inputValidation
    case technologyResolution
    case workspaceSetup
    case adapterPreparation
    case backendExecution
    case parsing
    case irValidation
    case persistence
    case reporting

    public var description: String { rawValue }
}
