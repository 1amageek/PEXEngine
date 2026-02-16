import Foundation
import PEXEngine
import Configuration
import SystemPackage

private struct ConfigString: RawRepresentable, Sendable {
    let rawValue: String
    init?(rawValue: String) { self.rawValue = rawValue }
}

public struct ExtractCommand: Sendable {
    public let configURL: URL?
    public let jsonOutput: Bool
    public let directParams: DirectParams?

    public struct DirectParams: Sendable {
        public let layoutPath: String
        public let netlistPath: String
        public let topCell: String
        public let technologyPath: String
        public let backendID: String
        public let corners: [String]
        public let maxJobs: Int?
        public let includeCoupling: Bool?
        public let minCapF: Double?
        public let minResOhm: Double?
        public let outputPath: String?
        public let strict: Bool
    }

    public init(arguments: [String]) throws {
        var configPath: String?
        var json = false
        var layoutPath: String?
        var netlistPath: String?
        var topCell: String?
        var technologyPath: String?
        var backendID: String?
        var corners: [String] = []
        var maxJobs: Int?
        var includeCoupling: Bool?
        var minCapF: Double?
        var minResOhm: Double?
        var outputPath: String?
        var strict = false

        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--config":
                i += 1
                guard i < arguments.count else {
                    throw PEXError.invalidInput("--config requires a path argument")
                }
                configPath = arguments[i]
            case "--json":
                json = true
            case "--layout":
                i += 1
                guard i < arguments.count else {
                    throw PEXError.invalidInput("--layout requires a path argument")
                }
                layoutPath = arguments[i]
            case "--netlist":
                i += 1
                guard i < arguments.count else {
                    throw PEXError.invalidInput("--netlist requires a path argument")
                }
                netlistPath = arguments[i]
            case "--top-cell":
                i += 1
                guard i < arguments.count else {
                    throw PEXError.invalidInput("--top-cell requires a name argument")
                }
                topCell = arguments[i]
            case "--technology":
                i += 1
                guard i < arguments.count else {
                    throw PEXError.invalidInput("--technology requires a path argument")
                }
                technologyPath = arguments[i]
            case "--backend":
                i += 1
                guard i < arguments.count else {
                    throw PEXError.invalidInput("--backend requires an ID argument")
                }
                backendID = arguments[i]
            case "--corner":
                i += 1
                guard i < arguments.count else {
                    throw PEXError.invalidInput("--corner requires an ID argument")
                }
                corners.append(arguments[i])
            case "--max-jobs":
                i += 1
                guard i < arguments.count, let n = Int(arguments[i]), n > 0 else {
                    throw PEXError.invalidInput("--max-jobs requires a positive integer")
                }
                maxJobs = n
            case "--include-coupling":
                includeCoupling = true
            case "--min-cap-f":
                i += 1
                guard i < arguments.count, let v = Double(arguments[i]) else {
                    throw PEXError.invalidInput("--min-cap-f requires a numeric value")
                }
                minCapF = v
            case "--min-res-ohm":
                i += 1
                guard i < arguments.count, let v = Double(arguments[i]) else {
                    throw PEXError.invalidInput("--min-res-ohm requires a numeric value")
                }
                minResOhm = v
            case "--out":
                i += 1
                guard i < arguments.count else {
                    throw PEXError.invalidInput("--out requires a path argument")
                }
                outputPath = arguments[i]
            case "--strict":
                strict = true
            default:
                break
            }
            i += 1
        }

        if let configPath {
            self.configURL = URL(filePath: configPath)
            self.directParams = nil
        } else if let layoutPath, let netlistPath, let topCell, let technologyPath {
            self.configURL = nil
            self.directParams = DirectParams(
                layoutPath: layoutPath,
                netlistPath: netlistPath,
                topCell: topCell,
                technologyPath: technologyPath,
                backendID: backendID ?? "mock",
                corners: corners.isEmpty ? ["tt_25c_1v0"] : corners,
                maxJobs: maxJobs,
                includeCoupling: includeCoupling,
                minCapF: minCapF,
                minResOhm: minResOhm,
                outputPath: outputPath,
                strict: strict
            )
        } else if layoutPath != nil || netlistPath != nil || topCell != nil || technologyPath != nil {
            throw PEXError.invalidInput("Direct parameter mode requires --layout, --netlist, --top-cell, and --technology")
        } else {
            self.configURL = nil
            self.directParams = nil
        }

        self.jsonOutput = json
    }

    public func run() async throws {
        let engine = DefaultPEXEngine.withDefaults()

        let request: PEXRunRequest
        if let configURL {
            request = try await buildRequestFromConfigFile(configURL)
        } else if let params = directParams {
            request = buildRequestFromDirectParams(params)
        } else {
            throw PEXError.invalidInput("Either --config <path> or direct parameters (--layout, --netlist, --top-cell, --technology) are required")
        }

        let result = try await engine.run(request)

        // 結果を出力（CI で stdout から診断情報を取得できるように先に出力）
        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(result)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            let formatter = CLIOutputFormatter()
            print(formatter.formatResult(result))
        }

        // status に基づいて終了コードを制御
        switch result.status {
        case .success:
            break
        case .partialSuccess:
            throw PEXError(
                kind: .backendExecutionFailed,
                stage: .backendExecution,
                message: "\(result.metrics.failureCount) of \(result.metrics.cornerCount) corners failed"
            )
        case .failed:
            throw PEXError(
                kind: .backendExecutionFailed,
                stage: .backendExecution,
                message: "All \(result.metrics.cornerCount) corners failed"
            )
        }
    }

    func buildRequestFromConfigFile(_ configURL: URL) async throws -> PEXRunRequest {
        let filePath = FilePath(configURL.path(percentEncoded: false))
        let provider: JSONProvider
        do {
            provider = try await JSONProvider(filePath: filePath)
        } catch {
            throw PEXError.invalidInput("Failed to read config file: \(configURL.path(percentEncoded: false))")
        }

        let defaults = InMemoryProvider(values: [
            "topCell": "TOP",
            "backendID": "mock",
            "inputs.layout": "top.oas",
            "inputs.netlist": "top.cir",
            "inputs.technology": "tech.json",
            "output.workspace": ".xcircuite/pex/runs",
            "options.includeCouplingCaps": true,
            "options.maxParallelJobs": 2,
            "options.strictValidation": false,
        ])

        let config = ConfigReader(providers: [provider, defaults])
        let baseDir = configURL.deletingLastPathComponent()

        let topCell = config.string(forKey: "topCell", default: "TOP")
        let backendID = config.string(forKey: "backendID", default: "mock")
        let executablePath = config.string(forKey: "executablePath")

        let layoutPath = config.string(forKey: "inputs.layout", default: "top.oas")
        let netlistPath = config.string(forKey: "inputs.netlist", default: "top.cir")
        let technologyPath = config.string(forKey: "inputs.technology", default: "tech.json")
        let workspacePath = config.string(forKey: "output.workspace", default: ".xcircuite/pex/runs")

        let includeCouplingCaps = config.bool(forKey: "options.includeCouplingCaps", default: true)
        let maxParallelJobs = config.int(forKey: "options.maxParallelJobs", default: 2)
        let strictValidation = config.bool(forKey: "options.strictValidation", default: false)
        let minCapacitanceF = config.double(forKey: "options.minCapacitanceF")
        let minResistanceOhm = config.double(forKey: "options.minResistanceOhm")

        let layoutURL = Self.resolveURL(layoutPath, relativeTo: baseDir)
        let netlistURL = Self.resolveURL(netlistPath, relativeTo: baseDir)
        let technologyURL = Self.resolveURL(technologyPath, relativeTo: baseDir)
        let workspaceURL = Self.resolveURL(workspacePath, relativeTo: baseDir)

        let corners: [PEXCorner]
        let defaultCorner = ConfigString(rawValue: "tt_25c_1v0")!
        let cornerValues = config.stringArray(forKey: "corners", as: ConfigString.self, default: [defaultCorner])
        let filtered = cornerValues.map { $0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if filtered.isEmpty {
            corners = [PEXCorner(id: "tt_25c_1v0")]
        } else {
            corners = filtered.map { PEXCorner(id: $0) }
        }

        let options = PEXRunOptions(
            extractMode: .rc,
            includeCouplingCaps: includeCouplingCaps,
            minCapacitanceF: minCapacitanceF,
            minResistanceOhm: minResistanceOhm,
            maxParallelJobs: maxParallelJobs,
            emitRawArtifacts: true,
            emitIRJSON: true,
            strictValidation: strictValidation
        )

        return PEXRunRequest(
            layoutURL: layoutURL,
            layoutFormat: Self.detectLayoutFormat(layoutPath),
            sourceNetlistURL: netlistURL,
            sourceNetlistFormat: .spice,
            topCell: topCell,
            corners: corners,
            technology: .jsonFile(technologyURL),
            backendSelection: PEXBackendSelection(
                backendID: backendID,
                executablePath: executablePath
            ),
            options: options,
            workingDirectory: workspaceURL
        )
    }

    public func buildRequestFromDirectParams(_ params: DirectParams) -> PEXRunRequest {
        let layoutURL = URL(filePath: params.layoutPath)
        let netlistURL = URL(filePath: params.netlistPath)
        let technologyURL = URL(filePath: params.technologyPath)
        let workingDir = params.outputPath.map { URL(filePath: $0) }

        let layoutFormat: LayoutFormat
        let ext = layoutURL.pathExtension.lowercased()
        if ext == "oas" || ext == "oasis" {
            layoutFormat = .oas
        } else {
            layoutFormat = .gds
        }

        let corners = params.corners.map { PEXCorner(id: $0) }

        let options = PEXRunOptions(
            extractMode: .rc,
            includeCouplingCaps: params.includeCoupling ?? true,
            minCapacitanceF: params.minCapF,
            minResistanceOhm: params.minResOhm,
            maxParallelJobs: params.maxJobs ?? 2,
            emitRawArtifacts: true,
            emitIRJSON: true,
            strictValidation: params.strict
        )

        return PEXRunRequest(
            layoutURL: layoutURL,
            layoutFormat: layoutFormat,
            sourceNetlistURL: netlistURL,
            sourceNetlistFormat: .spice,
            topCell: params.topCell,
            corners: corners,
            technology: .jsonFile(technologyURL),
            backendSelection: PEXBackendSelection(backendID: params.backendID),
            options: options,
            workingDirectory: workingDir
        )
    }

    private static func resolveURL(_ path: String, relativeTo baseDir: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(filePath: path)
        }
        return baseDir.appending(path: path)
    }

    private static func detectLayoutFormat(_ path: String) -> LayoutFormat {
        let lower = path.lowercased()
        if lower.hasSuffix(".oas") || lower.hasSuffix(".oasis") {
            return .oas
        }
        return .gds
    }
}
