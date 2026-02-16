import Foundation
import PEXEngine

public struct ListBackendsCommand: Sendable {
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        self.jsonOutput = arguments.contains("--json")
    }

    public func run() throws {
        let adapterRegistry = PEXAdapterRegistry(adapters: [MockPEXAdapter()])
        let backends = adapterRegistry.registeredBackends

        if jsonOutput {
            let allEntries = backends.compactMap { id -> BackendEntry? in
                guard let adapter = adapterRegistry.adapter(for: id) else { return nil }
                let caps = adapter.capabilities
                return BackendEntry(
                    id: id,
                    supportsCouplingCaps: caps.supportsCouplingCaps,
                    supportsCornerSweep: caps.supportsCornerSweep,
                    supportsIncremental: caps.supportsIncremental,
                    supportsRCReduction: caps.supportsRCReduction,
                    nativeOutputFormats: caps.nativeOutputFormats.map(\.rawValue)
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(allEntries)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            print("Registered backends:")
            for id in backends {
                if let adapter = adapterRegistry.adapter(for: id) {
                    let caps = adapter.capabilities
                    print("  - \(id)")
                    print("    Coupling: \(caps.supportsCouplingCaps), Corner Sweep: \(caps.supportsCornerSweep)")
                    print("    Incremental: \(caps.supportsIncremental), RC Reduction: \(caps.supportsRCReduction)")
                    print("    Formats: \(caps.nativeOutputFormats.map(\.rawValue).joined(separator: ", "))")
                }
            }
        }
    }
}

struct BackendEntry: Codable {
    let id: String
    let supportsCouplingCaps: Bool
    let supportsCornerSweep: Bool
    let supportsIncremental: Bool
    let supportsRCReduction: Bool
    let nativeOutputFormats: [String]
}
