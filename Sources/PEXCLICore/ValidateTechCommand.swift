import Foundation
import PEXEngine

public struct ValidateTechCommand: Sendable {
    public let technologyURL: URL
    public let strict: Bool
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        var techPath: String?
        var strict = false
        var json = false
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--technology":
                i += 1
                guard i < arguments.count else {
                    throw PEXError.invalidInput("--technology requires a path argument")
                }
                techPath = arguments[i]
            case "--strict":
                strict = true
            case "--json":
                json = true
            default:
                break
            }
            i += 1
        }

        guard let techPath else {
            throw PEXError.invalidInput("--technology <path> is required for validate-tech command")
        }

        self.technologyURL = URL(filePath: techPath)
        self.strict = strict
        self.jsonOutput = json
    }

    public func run() async throws {
        let resolver = TechnologyResolver()
        let ir = try resolver.resolve(.jsonFile(technologyURL))

        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(TechValidationResult(ir: ir))
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("Technology validation: OK")
            print("  Process: \(ir.processName)")
            print("  Layers: \(ir.stack.count)")
            print("  Vias: \(ir.vias.count)")
            print("  Layer map entries: \(ir.logicalToPhysicalLayerMap.count)")
            print("  Backend hints: \(ir.backendHints.count) backend(s)")

            if strict {
                var issues: [String] = []
                if ir.stack.isEmpty {
                    issues.append("No layers defined in technology stack")
                }
                if ir.processName.isEmpty {
                    issues.append("Process name is empty")
                }
                if !issues.isEmpty {
                    for issue in issues {
                        fputs("warning: \(issue)\n", stderr)
                    }
                    throw PEXError.technologyResolutionFailed(
                        "Strict validation failed with \(issues.count) issue(s)"
                    )
                }
            }
        }
    }
}

struct TechValidationResult: Codable {
    let valid: Bool
    let processName: String
    let layerCount: Int
    let viaCount: Int
    let layerMapEntries: Int
    let backendHintCount: Int

    init(ir: TechnologyIR) {
        self.valid = true
        self.processName = ir.processName
        self.layerCount = ir.stack.count
        self.viaCount = ir.vias.count
        self.layerMapEntries = ir.logicalToPhysicalLayerMap.count
        self.backendHintCount = ir.backendHints.count
    }
}
