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
    public let includeSummary: Bool
    public let summaryTopNets: Int
    public let directParams: DirectParams?
    public let strictValidationOverride: Bool?

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
        public let processProfile: PEXProcessProfileReference?
        public let strict: Bool
    }

    public init(arguments: [String]) throws {
        let parsed = try ExtractCommandArguments(arguments: arguments)
        if let configPath = parsed.configPath {
            self.configURL = URL(filePath: configPath)
            self.directParams = nil
        } else if let directParams = try parsed.makeDirectParams() {
            self.configURL = nil
            self.directParams = directParams
        } else {
            self.configURL = nil
            self.directParams = nil
        }

        self.jsonOutput = parsed.jsonOutput
        self.includeSummary = parsed.includeSummary
        self.summaryTopNets = parsed.summaryTopNets
        self.strictValidationOverride = parsed.strictOverride
    }

    public func run() async throws {
        let engine = DefaultPEXEngine.withDefaults()
        let request = try await buildRunRequest()
        let result = try await engine.run(request)
        try await emit(result)
        try validate(result)
    }

    private func buildRunRequest() async throws -> PEXRunRequest {
        if let configURL {
            return try await buildRequestFromConfigFile(configURL)
        } else if let params = directParams {
            return buildRequestFromDirectParams(params)
        }
        throw PEXError.invalidInput("Either --config <path> or direct parameters (--layout, --netlist, --top-cell, --technology) are required")
    }

    private func emit(_ result: PEXRunResult) async throws {
        if jsonOutput {
            let output = try buildJSONOutput(for: result)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(output)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            let formatter = CLIOutputFormatter()
            print(formatter.formatResult(result))
            if includeSummary {
                let summaryCommand = try makeSummaryCommand(for: result)
                try await summaryCommand.run()
            }
        }
    }

    private func validate(_ result: PEXRunResult) throws {
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

    public func buildJSONOutput(for result: PEXRunResult) throws -> ExtractJSONOutput {
        let resolver = try PEXArtifactResolver(manifestURL: result.manifestURL)
        let summary = includeSummary ? try makeSummaryCommand(for: result).buildSummary().summary : nil
        return ExtractJSONOutput(
            runID: result.runID.description,
            status: result.status.rawValue,
            manifestURL: result.manifestURL,
            completeness: resolver.completenessReport(),
            metrics: result.metrics,
            warnings: result.warnings,
            extractorRun: result.extractorRun,
            summary: summary
        )
    }

    private func makeSummaryCommand(for result: PEXRunResult) throws -> SummarizeCommand {
        try SummarizeCommand(arguments: [
            "--run",
            result.manifestURL.path(percentEncoded: false),
            "--top-nets",
            "\(summaryTopNets)",
        ])
    }

    func buildRequestFromConfigFile(_ configURL: URL) async throws -> PEXRunRequest {
        let provider = try await Self.loadConfigProvider(configURL)
        let config = ConfigReader(providers: [provider, Self.defaults])
        let baseDir = configURL.deletingLastPathComponent()
        let topCell = config.string(forKey: "topCell", default: "TOP")
        let backendID = try Self.requiredBackendID(config.string(forKey: "backendID"), source: "config backendID")
        let executablePath = config.string(forKey: "executablePath")
        let layoutPath = config.string(forKey: "inputs.layout", default: "top.oas")
        let netlistPath = config.string(forKey: "inputs.netlist", default: "top.cir")
        let technologyPath = config.string(forKey: "inputs.technology", default: "tech.json")
        let workspacePath = config.string(forKey: "output.workspace", default: ".xcircuite/pex/runs")

        return PEXRunRequest(
            layoutURL: Self.resolveURL(layoutPath, relativeTo: baseDir),
            layoutFormat: Self.detectLayoutFormat(layoutPath),
            sourceNetlistURL: Self.resolveURL(netlistPath, relativeTo: baseDir),
            sourceNetlistFormat: .spice,
            topCell: topCell,
            corners: try Self.configuredCorners(from: config),
            technology: .jsonFile(Self.resolveURL(technologyPath, relativeTo: baseDir)),
            processProfile: Self.configuredProcessProfile(from: config),
            backendSelection: PEXBackendSelection(
                backendID: backendID,
                executablePath: executablePath
            ),
            options: Self.configuredOptions(from: config, strictOverride: strictValidationOverride),
            workingDirectory: Self.resolveURL(workspacePath, relativeTo: baseDir)
        )
    }

    private static var defaults: InMemoryProvider {
        InMemoryProvider(values: [
            "topCell": "TOP",
            "inputs.layout": "top.oas",
            "inputs.netlist": "top.cir",
            "inputs.technology": "tech.json",
            "output.workspace": ".xcircuite/pex/runs",
            "options.includeCouplingCaps": true,
            "options.maxParallelJobs": 2,
            "options.strictValidation": true,
        ])
    }

    private static func loadConfigProvider(_ configURL: URL) async throws -> FileProvider<JSONSnapshot> {
        let filePath = FilePath(configURL.path(percentEncoded: false))
        do {
            return try await FileProvider<JSONSnapshot>(filePath: filePath)
        } catch {
            throw PEXError.invalidInput("Failed to read config file: \(configURL.path(percentEncoded: false))")
        }
    }

    private static func configuredProcessProfile(from config: ConfigReader) -> PEXProcessProfileReference? {
        makeProcessProfile(
            profileID: config.string(forKey: "processProfile.profileID"),
            pdkID: config.string(forKey: "processProfile.pdkID"),
            source: config.string(forKey: "processProfile.source"),
            requirementID: config.string(forKey: "processProfile.requirementID"),
            pdkRoot: config.string(forKey: "processProfile.pdkRoot"),
            primaryDeckPath: config.string(forKey: "processProfile.primaryDeckPath")
        )
    }

    private static func configuredCorners(from config: ConfigReader) throws -> [PEXCorner] {
        guard let defaultCorner = ConfigString(rawValue: "tt_25c_1v0") else {
            throw PEXError.invalidInput("Default PEX corner identifier is invalid")
        }
        let cornerValues = config.stringArray(forKey: "corners", as: ConfigString.self, default: [defaultCorner])
        let filtered = cornerValues
            .map { $0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return filtered.isEmpty ? [PEXCorner(id: "tt_25c_1v0")] : filtered.map { PEXCorner(id: $0) }
    }

    fileprivate static func requiredBackendID(_ value: String?, source: String) throws -> String {
        guard let value else {
            throw PEXError.invalidInput("\(source) is required; pass --backend <id> or set backendID explicitly")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PEXError.invalidInput("\(source) must not be empty")
        }
        return trimmed
    }

    private static func configuredOptions(
        from config: ConfigReader,
        strictOverride: Bool?
    ) -> PEXRunOptions {
        PEXRunOptions(
            extractMode: .rc,
            includeCouplingCaps: config.bool(forKey: "options.includeCouplingCaps", default: true),
            minCapacitanceF: config.double(forKey: "options.minCapacitanceF"),
            minResistanceOhm: config.double(forKey: "options.minResistanceOhm"),
            maxParallelJobs: config.int(forKey: "options.maxParallelJobs", default: 2),
            emitRawArtifacts: true,
            emitIRJSON: true,
            strictValidation: strictOverride ?? config.bool(forKey: "options.strictValidation", default: true)
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
            processProfile: params.processProfile,
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

    fileprivate static func makeProcessProfile(
        profileID: String?,
        pdkID: String?,
        source: String?,
        requirementID: String?,
        pdkRoot: String?,
        primaryDeckPath: String?
    ) -> PEXProcessProfileReference? {
        let values = [profileID, pdkID, source, requirementID, pdkRoot, primaryDeckPath]
        guard values.contains(where: { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return nil
        }
        return PEXProcessProfileReference(
            profileID: profileID,
            pdkID: pdkID,
            source: source,
            requirementID: requirementID,
            pdkRoot: pdkRoot,
            primaryDeckPath: primaryDeckPath
        )
    }
}

private struct ExtractCommandArguments {
    var configPath: String?
    var jsonOutput = false
    var includeSummary = false
    var summaryTopNets = 10
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
    var processProfileID: String?
    var pdkID: String?
    var processProfileSource: String?
    var processRequirementID: String?
    var pdkRoot: String?
    var primaryDeckPath: String?
    var strictOverride: Bool?

    init(arguments: [String]) throws {
        var cursor = ExtractArgumentCursor(arguments: arguments)
        while let argument = cursor.next() {
            try apply(argument: argument, cursor: &cursor)
        }
    }

    func makeDirectParams() throws -> ExtractCommand.DirectParams? {
        if let layoutPath, let netlistPath, let topCell, let technologyPath {
            return ExtractCommand.DirectParams(
                layoutPath: layoutPath,
                netlistPath: netlistPath,
                topCell: topCell,
                technologyPath: technologyPath,
                backendID: try ExtractCommand.requiredBackendID(backendID, source: "--backend"),
                corners: corners.isEmpty ? ["tt_25c_1v0"] : corners,
                maxJobs: maxJobs,
                includeCoupling: includeCoupling,
                minCapF: minCapF,
                minResOhm: minResOhm,
                outputPath: outputPath,
                processProfile: makeProcessProfile(),
                strict: strictOverride ?? true
            )
        }
        guard layoutPath == nil, netlistPath == nil, topCell == nil, technologyPath == nil else {
            throw PEXError.invalidInput("Direct parameter mode requires --layout, --netlist, --top-cell, and --technology")
        }
        return nil
    }

    private mutating func apply(argument: String, cursor: inout ExtractArgumentCursor) throws {
        switch argument {
        case "--config":
            configPath = try cursor.requireValue(for: argument, description: "a path argument")
        case "--json":
            jsonOutput = true
        case "--summary":
            includeSummary = true
        case "--summary-top-nets":
            summaryTopNets = try cursor.requirePositiveInt(for: argument)
        case "--layout":
            layoutPath = try cursor.requireValue(for: argument, description: "a path argument")
        case "--netlist":
            netlistPath = try cursor.requireValue(for: argument, description: "a path argument")
        case "--top-cell":
            topCell = try cursor.requireValue(for: argument, description: "a name argument")
        case "--technology":
            technologyPath = try cursor.requireValue(for: argument, description: "a path argument")
        case "--backend":
            backendID = try cursor.requireValue(for: argument, description: "an ID argument")
        case "--corner":
            corners.append(try cursor.requireValue(for: argument, description: "an ID argument"))
        case "--max-jobs":
            maxJobs = try cursor.requirePositiveInt(for: argument)
        case "--include-coupling":
            includeCoupling = true
        case "--min-cap-f":
            minCapF = try cursor.requireDouble(for: argument)
        case "--min-res-ohm":
            minResOhm = try cursor.requireDouble(for: argument)
        case "--out":
            outputPath = try cursor.requireValue(for: argument, description: "a path argument")
        case "--process-profile-id":
            processProfileID = try cursor.requireValue(for: argument, description: "an ID argument")
        case "--pdk-id":
            pdkID = try cursor.requireValue(for: argument, description: "an ID argument")
        case "--process-profile-source":
            processProfileSource = try cursor.requireValue(for: argument, description: "a source argument")
        case "--process-requirement":
            processRequirementID = try cursor.requireValue(for: argument, description: "an ID argument")
        case "--pdk-root":
            pdkRoot = try cursor.requireValue(for: argument, description: "a path argument")
        case "--primary-deck":
            primaryDeckPath = try cursor.requireValue(for: argument, description: "a path argument")
        case "--strict":
            strictOverride = true
        case "--non-strict":
            strictOverride = false
        default:
            throw PEXError.invalidInput("Unknown extract argument '\(argument)'")
        }
    }

    private func makeProcessProfile() -> PEXProcessProfileReference? {
        ExtractCommand.makeProcessProfile(
            profileID: processProfileID,
            pdkID: pdkID,
            source: processProfileSource,
            requirementID: processRequirementID,
            pdkRoot: pdkRoot,
            primaryDeckPath: primaryDeckPath
        )
    }
}

private struct ExtractArgumentCursor {
    let arguments: [String]
    var index = 0

    mutating func next() -> String? {
        guard index < arguments.count else { return nil }
        let value = arguments[index]
        index += 1
        return value
    }

    mutating func requireValue(for option: String, description: String) throws -> String {
        guard let value = next() else {
            throw PEXError.invalidInput("\(option) requires \(description)")
        }
        return value
    }

    mutating func requirePositiveInt(for option: String) throws -> Int {
        let value = try requireValue(for: option, description: "a positive integer")
        guard let parsed = Int(value), parsed > 0 else {
            throw PEXError.invalidInput("\(option) requires a positive integer")
        }
        return parsed
    }

    mutating func requireDouble(for option: String) throws -> Double {
        let value = try requireValue(for: option, description: "a numeric value")
        guard let parsed = Double(value) else {
            throw PEXError.invalidInput("\(option) requires a numeric value")
        }
        return parsed
    }
}

public struct ExtractJSONOutput: Sendable, Codable {
    let runID: String
    let status: String
    let manifestURL: URL
    let completeness: PEXArtifactCompletenessReport
    let metrics: PEXRunMetrics
    let warnings: [PEXWarning]
    let extractorRun: PEXExtractorRunResult?
    let summary: PEXRunSummary?
}
