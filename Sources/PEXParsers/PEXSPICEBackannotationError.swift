import Foundation

public enum PEXSPICEBackannotationError: Error, Sendable, Equatable, LocalizedError {
    case emptySourceNetlist
    case sourceReadFailed(String)
    case missingGeneratedSubcircuit
    case missingGeneratedPorts
    case unmatchedSourcePort(String)
    case topCellNotFound(String)
    case instanceNameCollision(String)
    case subcircuitNameCollision(String)
    case writer(PEXSPICEWriterError)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptySourceNetlist:
            return "Source SPICE netlist is empty"
        case .sourceReadFailed(let path):
            return "Failed to read source SPICE netlist: \(path)"
        case .missingGeneratedSubcircuit:
            return "Generated SPICE backannotation is missing its subcircuit declaration"
        case .missingGeneratedPorts:
            return "Generated SPICE backannotation has no connectable ports"
        case .unmatchedSourcePort(let port):
            return "PEX port '\(port)' was not found in the source netlist"
        case .topCellNotFound(let topCell):
            return "Top cell '\(topCell)' was not found in the source netlist"
        case .instanceNameCollision(let name):
            return "PEX backannotation instance name collides with source netlist: \(name)"
        case .subcircuitNameCollision(let name):
            return "PEX backannotation subcircuit name collides with source netlist: \(name)"
        case .writer(let error):
            return "Failed to generate SPICE backannotation: \(error.localizedDescription)"
        case .writeFailed(let path):
            return "Failed to write SPICE backannotated netlist to \(path)"
        }
    }
}
