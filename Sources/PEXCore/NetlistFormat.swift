import Foundation

public enum NetlistFormat: String, Sendable, Codable, Hashable, CustomStringConvertible {
    case spice
    case cdl
    case verilog

    public var description: String { rawValue }
}
