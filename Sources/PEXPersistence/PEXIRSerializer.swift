import Foundation
import PEXCore

public struct PEXIRSerializer: Sendable {
    public init() {}

    public func encode(_ ir: ParasiticIR) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(ir)
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to encode ParasiticIR to JSON",
                underlying: error
            )
        }
    }

    public func decode(from data: Data) throws -> ParasiticIR {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(ParasiticIR.self, from: data)
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to decode ParasiticIR from JSON",
                underlying: error
            )
        }
    }
}
