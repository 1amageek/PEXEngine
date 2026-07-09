import Foundation
import PEXEngine

public struct ListBackendsCommand: Sendable {
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        var json = false
        for argument in arguments {
            switch argument {
            case "--json":
                json = true
            default:
                throw PEXError.invalidInput("Unknown list-backends argument: \(argument)")
            }
        }
        self.jsonOutput = json
    }

    func buildEntries() throws -> [BackendEntry] {
        let adapterRegistry = PEXAdapterRegistry(adapters: PEXDefaultBackends.makeAll())
        let backends = adapterRegistry.registeredBackends
        return try backends.map { id -> BackendEntry in
            guard let adapter = adapterRegistry.adapter(for: id) else {
                throw PEXError.internalInvariantViolation(
                    "Registered backend '\(id)' is missing its adapter instance."
                )
            }
            let caps = adapter.capabilities
            return BackendEntry(
                id: id,
                supportsCouplingCaps: caps.supportsCouplingCaps,
                supportsCornerSweep: caps.supportsCornerSweep,
                supportsIncremental: caps.supportsIncremental,
                supportsRCReduction: caps.supportsRCReduction,
                nativeOutputFormats: caps.nativeOutputFormats.map(\.rawValue),
                readiness: Self.toolReadiness(adapter)
            )
        }
    }

    public func run() throws {
        let allEntries = try buildEntries()
        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(allEntries)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            print("Registered backends:")
            for entry in allEntries {
                print("  - \(entry.id)")
                print("    Coupling: \(entry.supportsCouplingCaps), Corner Sweep: \(entry.supportsCornerSweep)")
                print("    Incremental: \(entry.supportsIncremental), RC Reduction: \(entry.supportsRCReduction)")
                print("    Formats: \(entry.nativeOutputFormats.joined(separator: ", "))")
                print("    Readiness: \(entry.readiness.status.rawValue) - \(entry.readiness.reason)")
            }
        }
    }

    private static func toolReadiness(_ adapter: any PEXAdapter) -> PEXExtractorToolReadiness {
        if let provider = adapter as? PEXAdapterReadinessProviding {
            return provider.toolReadiness(processProfile: nil)
        }
        return PEXExtractorToolReadiness(
            backendID: adapter.backendID,
            status: .unknown,
            reason: "Backend does not expose a typed extractor readiness provider.",
            capabilities: adapter.capabilities,
            diagnostics: [
                PEXExtractorDiagnostic(
                    diagnosticID: "\(adapter.backendID):readiness-provider-missing",
                    code: "readiness_provider_missing",
                    severity: .warning,
                    message: "Backend can be listed, but tool readiness cannot be inspected before execution.",
                    suggestedActions: ["run_backend_with_artifact_capture"]
                )
            ],
            suggestedActions: ["run_backend_with_artifact_capture"]
        )
    }
}

struct BackendEntry: Codable {
    let id: String
    let supportsCouplingCaps: Bool
    let supportsCornerSweep: Bool
    let supportsIncremental: Bool
    let supportsRCReduction: Bool
    let nativeOutputFormats: [String]
    let readiness: PEXExtractorToolReadiness
}
