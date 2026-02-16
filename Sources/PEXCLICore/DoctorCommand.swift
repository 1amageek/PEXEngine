import Foundation
import PEXEngine

public struct DoctorCommand: Sendable {
    public let jsonOutput: Bool

    public init(arguments: [String]) {
        var json = false
        for arg in arguments {
            if arg == "--json" {
                json = true
            }
        }
        self.jsonOutput = json
    }

    public func run() async throws {
        let engine = DefaultPEXEngine.withDefaults()

        let adapterRegistry = PEXAdapterRegistry(adapters: [MockPEXAdapter()])
        let parserRegistry = PEXParserRegistry()
        parserRegistry.register(SPEFPEXParser())

        var checks: [DiagnosticCheck] = []

        let registeredFormats = parserRegistry.registeredFormats
        checks.append(DiagnosticCheck(
            name: "Parser Registration",
            status: registeredFormats.isEmpty ? .warning : .ok,
            detail: registeredFormats.isEmpty
                ? "No parsers registered"
                : "Registered formats: \(registeredFormats.map(\.rawValue).sorted().joined(separator: ", "))"
        ))

        let registeredBackends = adapterRegistry.registeredBackends
        var backendDetails: [BackendDetail] = []
        for backendID in registeredBackends {
            if let adapter = adapterRegistry.adapter(for: backendID) {
                let caps = adapter.capabilities
                backendDetails.append(BackendDetail(
                    id: backendID,
                    coupling: caps.supportsCouplingCaps,
                    cornerSweep: caps.supportsCornerSweep,
                    incremental: caps.supportsIncremental,
                    rcReduction: caps.supportsRCReduction,
                    formats: caps.nativeOutputFormats.map(\.rawValue)
                ))
            }
        }
        checks.append(DiagnosticCheck(
            name: "Backend Registration",
            status: registeredBackends.isEmpty ? .warning : .ok,
            detail: registeredBackends.isEmpty
                ? "No backends registered"
                : "Registered: \(registeredBackends.joined(separator: ", "))"
        ))

        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appending(path: "pex_doctor_\(UUID().uuidString).tmp")
        let tempWritable: Bool
        do {
            try Data("test".utf8).write(to: testFile)
            try FileManager.default.removeItem(at: testFile)
            tempWritable = true
        } catch {
            tempWritable = false
        }
        checks.append(DiagnosticCheck(
            name: "Temp Directory",
            status: tempWritable ? .ok : .error,
            detail: tempWritable
                ? "Writable: \(tempDir.path(percentEncoded: false))"
                : "Not writable: \(tempDir.path(percentEncoded: false))"
        ))

        checks.append(DiagnosticCheck(
            name: "Engine",
            status: .ok,
            detail: "DefaultPEXEngine instantiated successfully"
        ))
        _ = engine

        if jsonOutput {
            let report = DoctorReport(checks: checks, backends: backendDetails)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("pexengine doctor")
            print("================")
            print("")
            for check in checks {
                let marker: String
                switch check.status {
                case .ok: marker = "[OK]"
                case .warning: marker = "[WARN]"
                case .error: marker = "[FAIL]"
                }
                print("  \(marker) \(check.name): \(check.detail)")
            }

            if !backendDetails.isEmpty {
                print("")
                print("Backends:")
                for bd in backendDetails {
                    print("  \(bd.id):")
                    print("    Coupling: \(bd.coupling), Corner Sweep: \(bd.cornerSweep)")
                    print("    Incremental: \(bd.incremental), RC Reduction: \(bd.rcReduction)")
                    print("    Formats: \(bd.formats.joined(separator: ", "))")
                }
            }

            let hasErrors = checks.contains { $0.status == .error }
            print("")
            print(hasErrors ? "Some checks failed." : "All checks passed.")
        }
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
}

struct DoctorReport: Codable {
    let checks: [DiagnosticCheck]
    let backends: [BackendDetail]
}
