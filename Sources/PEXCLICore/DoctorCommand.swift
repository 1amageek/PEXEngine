import Foundation
import PEXEngine

public struct DoctorCommand: Sendable {
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        var json = false
        for arg in arguments {
            switch arg {
            case "--json":
                json = true
            default:
                throw PEXError.invalidInput("Unknown doctor argument: \(arg)")
            }
        }
        self.jsonOutput = json
    }

    func buildReport() -> DoctorReport {
        let adapterRegistry = PEXAdapterRegistry(adapters: PEXDefaultBackends.makeAll())
        let parserRegistry = PEXDefaultParsers.makeRegistry()
        let checks = [
            Self.parserRegistrationCheck(parserRegistry),
            Self.backendRegistrationCheck(adapterRegistry),
            Self.tempDirectoryCheck(),
            Self.engineCheck(),
        ]
        return DoctorReport(checks: checks, backends: Self.backendDetails(from: adapterRegistry))
    }

    private static func parserRegistrationCheck(_ parserRegistry: PEXParserRegistry) -> DiagnosticCheck {
        let registeredFormats = parserRegistry.registeredFormats
        return DiagnosticCheck(
            name: "Parser Registration",
            status: registeredFormats.isEmpty ? .warning : .ok,
            detail: registeredFormats.isEmpty
                ? "No parsers registered"
                : "Registered formats: \(registeredFormats.map(\.rawValue).sorted().joined(separator: ", "))"
        )
    }

    private static func backendRegistrationCheck(_ adapterRegistry: PEXAdapterRegistry) -> DiagnosticCheck {
        let registeredBackends = adapterRegistry.registeredBackends
        return DiagnosticCheck(
            name: "Backend Registration",
            status: registeredBackends.isEmpty ? .warning : .ok,
            detail: registeredBackends.isEmpty
                ? "No backends registered"
                : "Registered: \(registeredBackends.joined(separator: ", "))"
        )
    }

    private static func backendDetails(from adapterRegistry: PEXAdapterRegistry) -> [BackendDetail] {
        adapterRegistry.registeredBackends.compactMap { backendID in
            guard let adapter = adapterRegistry.adapter(for: backendID) else {
                return nil
            }
            let caps = adapter.capabilities
            return BackendDetail(
                id: backendID,
                coupling: caps.supportsCouplingCaps,
                cornerSweep: caps.supportsCornerSweep,
                incremental: caps.supportsIncremental,
                rcReduction: caps.supportsRCReduction,
                formats: caps.nativeOutputFormats.map(\.rawValue),
                readiness: Self.toolReadiness(adapter)
            )
        }
    }

    private static func tempDirectoryCheck() -> DiagnosticCheck {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appending(path: "pex_doctor_\(UUID().uuidString).tmp")
        let tempWritable: Bool
        let detail: String
        do {
            try Data("test".utf8).write(to: testFile)
            try FileManager.default.removeItem(at: testFile)
            tempWritable = true
            detail = "Writable: \(tempDir.path(percentEncoded: false))"
        } catch {
            tempWritable = false
            detail = "Not writable: \(tempDir.path(percentEncoded: false)); \(error.localizedDescription)"
        }
        return DiagnosticCheck(
            name: "Temp Directory",
            status: tempWritable ? .ok : .error,
            detail: detail
        )
    }

    private static func engineCheck() -> DiagnosticCheck {
        _ = DefaultPEXEngine.withDefaults()
        return DiagnosticCheck(
            name: "Engine",
            status: .ok,
            detail: "DefaultPEXEngine instantiated successfully"
        )
    }

    public func run() async throws {
        let report = buildReport()
        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("pexengine doctor")
            print("================")
            print("")
            for check in report.checks {
                let marker: String
                switch check.status {
                case .ok: marker = "[OK]"
                case .warning: marker = "[WARN]"
                case .error: marker = "[FAIL]"
                }
                print("  \(marker) \(check.name): \(check.detail)")
            }

            if !report.backends.isEmpty {
                print("")
                print("Backends:")
                for bd in report.backends {
                    print("  \(bd.id):")
                    print("    Coupling: \(bd.coupling), Corner Sweep: \(bd.cornerSweep)")
                    print("    Incremental: \(bd.incremental), RC Reduction: \(bd.rcReduction)")
                    print("    Formats: \(bd.formats.joined(separator: ", "))")
                    print("    Readiness: \(bd.readiness.status.rawValue) - \(bd.readiness.reason)")
                }
            }

            let hasErrors = report.checks.contains { $0.status == .error }
            print("")
            print(hasErrors ? "Some checks failed." : "All checks passed.")
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

enum CheckStatus: String, Codable {
    case ok
    case warning
    case error
}

struct DiagnosticCheck: Codable {
    let name: String
    let status: CheckStatus
    let detail: String
}

struct BackendDetail: Codable {
    let id: String
    let coupling: Bool
    let cornerSweep: Bool
    let incremental: Bool
    let rcReduction: Bool
    let formats: [String]
    let readiness: PEXExtractorToolReadiness
}

struct DoctorReport: Codable {
    let checks: [DiagnosticCheck]
    let backends: [BackendDetail]
}
