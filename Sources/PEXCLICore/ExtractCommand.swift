import Foundation
import CoreFoundation
import PEXEngine

private enum JSONConfigValue: Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: JSONConfigValue])
    case array([JSONConfigValue])
    case null

    init(_ value: Any) throws {
        if value is NSNull {
            self = .null
            return
        }
        if let object = value as? [String: Any] {
            var converted: [String: JSONConfigValue] = [:]
            for (key, value) in object {
                converted[key] = try JSONConfigValue(value)
            }
            self = .object(converted)
            return
        }
        if let array = value as? [Any] {
            self = .array(try array.map(JSONConfigValue.init))
            return
        }
        if let string = value as? String {
            self = .string(string)
            return
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .boolean(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
            return
        }
        throw PEXError.invalidInput("Configuration contains an unsupported JSON value")
    }
}

private struct ConfigReader: Sendable {
    private let values: JSONConfigValue
    private let defaults: JSONConfigValue?

    init(values: JSONConfigValue, defaults: JSONConfigValue? = nil) {
        self.values = values
        self.defaults = defaults
    }

    func string(forKey key: String) throws -> String? {
        guard let value = try lookup(key) else { return nil }
        guard case .string(let string) = value else {
            throw PEXError.invalidInput("Configuration \(key) must be a string")
        }
        return string
    }

    func string(forKey key: String, default defaultValue: String) throws -> String {
        try string(forKey: key) ?? defaultValue
    }

    func bool(forKey key: String, default defaultValue: Bool) throws -> Bool {
        guard let value = try lookup(key) else { return defaultValue }
        guard case .boolean(let boolean) = value else {
            throw PEXError.invalidInput("Configuration \(key) must be a boolean")
        }
        return boolean
    }

    func double(forKey key: String) throws -> Double? {
        guard let value = try lookup(key) else { return nil }
        guard case .number(let number) = value, number.isFinite, number >= 0 else {
            throw PEXError.invalidInput("Configuration \(key) must be a finite non-negative number")
        }
        return number
    }

    func int(forKey key: String, default defaultValue: Int) throws -> Int {
        guard let value = try lookup(key) else { return defaultValue }
        guard case .number(let number) = value, let integer = Int(exactly: number), integer > 0 else {
            throw PEXError.invalidInput("Configuration \(key) must be a positive representable integer")
        }
        return integer
    }

    func stringArray(forKey key: String) throws -> [String]? {
        guard let value = try lookup(key) else { return nil }
        guard case .array(let values) = value else {
            throw PEXError.invalidInput("Configuration \(key) must be an array of strings")
        }
        return try values.map { value in
            guard case .string(let string) = value else {
                throw PEXError.invalidInput("Configuration \(key) must contain only strings")
            }
            return string
        }
    }

    func stringDictionary(forKey key: String) throws -> [String: String] {
        guard let value = try lookup(key) else { return [:] }
        guard case .object(let values) = value else {
            throw PEXError.invalidInput("Configuration \(key) must be an object of strings")
        }
        var result: [String: String] = [:]
        for (name, value) in values {
            guard case .string(let string) = value,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PEXError.invalidInput("Configuration \(key) requires non-empty string keys and values")
            }
            result[name] = string
        }
        return result
    }

    private func lookup(_ key: String) throws -> JSONConfigValue? {
        try lookup(key, in: values) ?? defaults.flatMap { try lookup(key, in: $0) }
    }

    private func lookup(_ key: String, in value: JSONConfigValue) throws -> JSONConfigValue? {
        var current = value
        for component in key.split(separator: ".") {
            guard case .object(let object) = current else {
                throw PEXError.invalidInput("Configuration parent of \(key) must be an object")
            }
            guard let next = object[String(component)] else { return nil }
            current = next
        }
        return current
    }
}

public struct ExtractCommand: Sendable {
    public let configURL: URL?
    public let jsonOutput: Bool
    public let includeSummary: Bool
    public let summaryTopNets: Int
    public let directParams: DirectParams?
    public let strictValidationOverride: Bool?
    public let sourceConnectivityPolicyOverride: PEXSourceConnectivityPolicy?
    public let processProfileOverride: PEXProcessProfileReference?
    public let nativeInputURLOverride: URL?

    public struct DirectParams: Sendable {
        public let layoutPath: String
        public let netlistPath: String
        public let topCell: String
        public let technologyPath: String
        public let technologyByCorner: [String: String]
        public let backendID: String
        public let corners: [String]
        public let maxJobs: Int?
        public let includeCoupling: Bool?
        public let minCapF: Double?
        public let minResOhm: Double?
        public let outputPath: String?
        public let processProfile: PEXProcessProfileReference?
        public let nativeInputURL: URL?
        public let strict: Bool
        public let sourceConnectivityPolicy: PEXSourceConnectivityPolicy
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
        self.sourceConnectivityPolicyOverride = parsed.sourceConnectivityPolicyOverride
        self.processProfileOverride = parsed.makeProcessProfile()
        self.nativeInputURLOverride = parsed.nativeInputPath.map { URL(filePath: $0) }
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
            return try buildRequestFromDirectParams(params)
        }
        throw PEXError.invalidInput("Either --config <path> or direct parameters (--layout, --netlist, --top-cell, --technology) are required")
    }

    func emit(_ result: PEXRunResult) async throws {
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

    func validate(_ result: PEXRunResult) throws {
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
        let config = try Self.loadConfig(configURL)
        let baseDir = configURL.deletingLastPathComponent()
        let topCell = try config.string(forKey: "topCell", default: "TOP")
        let backendID = try Self.requiredBackendID(config.string(forKey: "backendID"), source: "config backendID")
        let executablePath = try config.string(forKey: "executablePath").map {
            Self.resolveURL($0, relativeTo: baseDir).path(percentEncoded: false)
        }
        let layoutPath = try config.string(forKey: "inputs.layout", default: "top.oas")
        let netlistPath = try config.string(forKey: "inputs.netlist", default: "top.cir")
        let technologyPath = try config.string(forKey: "inputs.technology", default: "tech.json")
        let technologyByCorner = try config.stringDictionary(forKey: "inputs.technologyByCorner").reduce(into: [String: TechnologyInput]()) { result, entry in
            result[entry.key] = .jsonFile(Self.resolveURL(entry.value, relativeTo: baseDir))
        }
        let workspacePath = try config.string(forKey: "output.workspace", default: ".xcircuite/pex/runs")
        let configuredNativePath = try config.string(forKey: "inputs.nativeInput")
        if let configuredNativePath, configuredNativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PEXError.invalidInput("Configuration inputs.nativeInput must not be empty")
        }
        let nativeInputURL = nativeInputURLOverride ?? configuredNativePath.map { Self.resolveURL($0, relativeTo: baseDir) }

        return PEXRunRequest(
            layoutURL: Self.resolveURL(layoutPath, relativeTo: baseDir),
            layoutFormat: Self.detectLayoutFormat(layoutPath),
            sourceNetlistURL: Self.resolveURL(netlistPath, relativeTo: baseDir),
            sourceNetlistFormat: .spice,
            topCell: topCell,
            corners: try Self.configuredCorners(from: config, backendID: backendID),
            technology: .jsonFile(Self.resolveURL(technologyPath, relativeTo: baseDir)),
            technologyByCorner: technologyByCorner,
            nativeInput: try PEXNativeInputLoader().load(backendID: backendID, referenceURL: nativeInputURL),
            processProfile: Self.mergedProcessProfile(
                try Self.configuredProcessProfile(from: config, relativeTo: baseDir),
                override: processProfileOverride
            ),
            backendSelection: PEXBackendSelection(
                backendID: backendID,
                executablePath: executablePath
            ),
            options: try Self.configuredOptions(
                from: config,
                strictOverride: strictValidationOverride,
                sourceConnectivityOverride: sourceConnectivityPolicyOverride
            ),
            workingDirectory: Self.resolveURL(workspacePath, relativeTo: baseDir)
        )
    }

    private static let defaults = JSONConfigValue.object([
        "topCell": .string("TOP"),
        "inputs": .object([
            "layout": .string("top.oas"),
            "netlist": .string("top.cir"),
            "technology": .string("tech.json"),
        ]),
        "output": .object([
            "workspace": .string(".xcircuite/pex/runs"),
        ]),
        "options": .object([
            "includeCouplingCaps": .boolean(true),
            "maxParallelJobs": .number(2),
            "strictValidation": .boolean(true),
            "sourceConnectivityPolicy": .string("warn"),
        ]),
    ])

    private static func loadConfig(_ configURL: URL) throws -> ConfigReader {
        let data: Data
        do {
            data = try Data(contentsOf: configURL)
        } catch {
            throw PEXError.invalidInput("Failed to read config file: \(configURL.path(percentEncoded: false))")
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let values = try JSONConfigValue(object)
            guard case .object = values else {
                throw PEXError.invalidInput("Configuration root must be a JSON object")
            }
            return ConfigReader(values: values, defaults: defaults)
        } catch let error as PEXError {
            throw error
        } catch {
            throw PEXError.invalidInput("Failed to decode config file: \(configURL.path(percentEncoded: false))")
        }
    }

    private static func configuredProcessProfile(
        from config: ConfigReader,
        relativeTo baseDir: URL
    ) throws -> PEXProcessProfileReference? {
        makeProcessProfile(
            profileID: try config.string(forKey: "processProfile.profileID"),
            pdkID: try config.string(forKey: "processProfile.pdkID"),
            source: try config.string(forKey: "processProfile.source"),
            requirementID: try config.string(forKey: "processProfile.requirementID"),
            pdkRoot: try config.string(forKey: "processProfile.pdkRoot").map { resolveURL($0, relativeTo: baseDir).path(percentEncoded: false) },
            primaryDeckPath: try config.string(forKey: "processProfile.primaryDeckPath").map { resolveURL($0, relativeTo: baseDir).path(percentEncoded: false) },
            cornerDeckPaths: try config.stringDictionary(forKey: "processProfile.cornerDeckPaths").reduce(into: [:]) { result, entry in
                result[entry.key] = resolveURL(entry.value, relativeTo: baseDir).path(percentEncoded: false)
            },
            requiredViewPaths: try config.stringDictionary(forKey: "processProfile.requiredViewPaths").reduce(into: [:]) { result, entry in
                result[entry.key] = resolveURL(entry.value, relativeTo: baseDir).path(percentEncoded: false)
            }
        )
    }

    private static func mergedProcessProfile(
        _ configProfile: PEXProcessProfileReference?,
        override: PEXProcessProfileReference?
    ) -> PEXProcessProfileReference? {
        guard let override else { return configProfile }
        guard let configProfile else { return override }
        return PEXProcessProfileReference(
            profileID: override.profileID ?? configProfile.profileID,
            pdkID: override.pdkID ?? configProfile.pdkID,
            source: override.source ?? configProfile.source,
            requirementID: override.requirementID ?? configProfile.requirementID,
            pdkRoot: override.pdkRoot ?? configProfile.pdkRoot,
            primaryDeckPath: override.primaryDeckPath ?? configProfile.primaryDeckPath,
            cornerDeckPaths: configProfile.cornerDeckPaths.merging(override.cornerDeckPaths) { _, override in override },
            requiredViewPaths: configProfile.requiredViewPaths.merging(override.requiredViewPaths) { _, override in override },
            metadata: configProfile.metadata.merging(override.metadata) { _, override in override }
        )
    }

    private static func configuredCorners(from config: ConfigReader, backendID: String) throws -> [PEXCorner] {
        try admittedCorners(config.stringArray(forKey: "corners"), backendID: backendID)
    }

    fileprivate static func admittedCorners(_ values: [String]?, backendID: String) throws -> [PEXCorner] {
        guard let values else {
            guard backendID != "native" else {
                throw PEXError.invalidInput("Native extraction requires explicit corners")
            }
            return [PEXCorner(id: "tt_25c_1v0")]
        }
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trimmed.isEmpty, trimmed.allSatisfy({ !$0.isEmpty }), Set(trimmed).count == trimmed.count else {
            throw PEXError.invalidInput("Corners must be non-empty, unique IDs")
        }
        return trimmed.map { PEXCorner(id: $0) }
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
        strictOverride: Bool?,
        sourceConnectivityOverride: PEXSourceConnectivityPolicy?
    ) throws -> PEXRunOptions {
        let configuredConnectivity: PEXSourceConnectivityPolicy?
        if let value = try config.string(forKey: "options.sourceConnectivityPolicy") {
            guard let policy = PEXSourceConnectivityPolicy(rawValue: value) else {
                throw PEXError.invalidInput("Configuration options.sourceConnectivityPolicy requires disabled, warn, or strict")
            }
            configuredConnectivity = policy
        } else {
            configuredConnectivity = nil
        }
        let configuredStrict = try config.bool(forKey: "options.strictValidation", default: true)
        return PEXRunOptions(
            extractMode: .rc,
            includeCouplingCaps: try config.bool(forKey: "options.includeCouplingCaps", default: true),
            minCapacitanceF: try config.double(forKey: "options.minCapacitanceF"),
            minResistanceOhm: try config.double(forKey: "options.minResistanceOhm"),
            maxParallelJobs: try config.int(forKey: "options.maxParallelJobs", default: 2),
            emitRawArtifacts: true,
            emitIRJSON: true,
            strictValidation: strictOverride ?? configuredStrict,
            sourceConnectivityPolicy: sourceConnectivityOverride ?? configuredConnectivity ?? .warn
        )
    }

    public func buildRequestFromDirectParams(_ params: DirectParams) throws -> PEXRunRequest {
        let layoutURL = URL(filePath: params.layoutPath)
        let netlistURL = URL(filePath: params.netlistPath)
        let technologyURL = URL(filePath: params.technologyPath)
        let workingDir = params.outputPath.map { URL(filePath: $0) }

        let layoutFormat: LayoutFormat
        let ext = layoutURL.pathExtension.lowercased()
        if ext == "def" {
            layoutFormat = .def
        } else if ext == "oas" || ext == "oasis" {
            layoutFormat = .oas
        } else {
            layoutFormat = .gds
        }

        let corners = try Self.admittedCorners(params.corners, backendID: params.backendID)

        let options = PEXRunOptions(
            extractMode: .rc,
            includeCouplingCaps: params.includeCoupling ?? true,
            minCapacitanceF: params.minCapF,
            minResistanceOhm: params.minResOhm,
            maxParallelJobs: params.maxJobs ?? 2,
            emitRawArtifacts: true,
            emitIRJSON: true,
            strictValidation: params.strict,
            sourceConnectivityPolicy: params.sourceConnectivityPolicy
        )

        return PEXRunRequest(
            layoutURL: layoutURL,
            layoutFormat: layoutFormat,
            sourceNetlistURL: netlistURL,
            sourceNetlistFormat: .spice,
            topCell: params.topCell,
            corners: corners,
            technology: .jsonFile(technologyURL),
            technologyByCorner: params.technologyByCorner.reduce(into: [String: TechnologyInput]()) { result, entry in
                result[entry.key] = .jsonFile(URL(filePath: entry.value))
            },
            nativeInput: try PEXNativeInputLoader().load(backendID: params.backendID, referenceURL: params.nativeInputURL),
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
        if lower.hasSuffix(".def") {
            return .def
        }
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
        primaryDeckPath: String?,
        cornerDeckPaths: [String: String] = [:],
        requiredViewPaths: [String: String] = [:]
    ) -> PEXProcessProfileReference? {
        let values = [profileID, pdkID, source, requirementID, pdkRoot, primaryDeckPath]
        guard values.contains(where: { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) || !cornerDeckPaths.isEmpty || !requiredViewPaths.isEmpty else {
            return nil
        }
        return PEXProcessProfileReference(
            profileID: profileID,
            pdkID: pdkID,
            source: source,
            requirementID: requirementID,
            pdkRoot: pdkRoot,
            primaryDeckPath: primaryDeckPath,
            cornerDeckPaths: cornerDeckPaths,
            requiredViewPaths: requiredViewPaths
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
    var technologyByCorner: [String: String] = [:]
    var backendID: String?
    var nativeInputPath: String?
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
    var cornerDeckPaths: [String: String] = [:]
    var requiredViewPaths: [String: String] = [:]
    var strictOverride: Bool?
    var sourceConnectivityPolicyOverride: PEXSourceConnectivityPolicy?

    init(arguments: [String]) throws {
        var cursor = ExtractArgumentCursor(arguments: arguments)
        while let argument = cursor.next() {
            try apply(argument: argument, cursor: &cursor)
        }
    }

    func makeDirectParams() throws -> ExtractCommand.DirectParams? {
        if let layoutPath, let netlistPath, let topCell, let technologyPath {
            let selectedBackendID = try ExtractCommand.requiredBackendID(backendID, source: "--backend")
            let admittedCorners = try ExtractCommand.admittedCorners(corners.isEmpty ? nil : corners, backendID: selectedBackendID)
            return ExtractCommand.DirectParams(
                layoutPath: layoutPath,
                netlistPath: netlistPath,
                topCell: topCell,
                technologyPath: technologyPath,
                technologyByCorner: technologyByCorner,
                backendID: selectedBackendID,
                corners: admittedCorners.map { $0.id.value },
                maxJobs: maxJobs,
                includeCoupling: includeCoupling,
                minCapF: minCapF,
                minResOhm: minResOhm,
                outputPath: outputPath,
                processProfile: makeProcessProfile(),
                nativeInputURL: nativeInputPath.map { URL(filePath: $0) },
                strict: strictOverride ?? true,
                sourceConnectivityPolicy: sourceConnectivityPolicyOverride ?? .warn
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
        case "--corner-technology":
            try recordCornerTechnology(cursor.requireValue(for: argument, description: "<corner-id>=<technology-path>"))
        case "--backend":
            backendID = try cursor.requireValue(for: argument, description: "an ID argument")
        case "--native-input":
            let path = try cursor.requireValue(for: argument, description: "a reference JSON path")
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PEXError.invalidInput("--native-input requires a non-empty reference JSON path")
            }
            nativeInputPath = path
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
        case "--corner-deck":
            try recordCornerDeck(cursor.requireValue(for: argument, description: "<corner-id>=<deck-path>"))
        case "--required-view":
            try recordRequiredView(cursor.requireValue(for: argument, description: "<role>=<path>"))
        case "--strict":
            strictOverride = true
        case "--non-strict":
            strictOverride = false
        case "--source-connectivity":
            let value = try cursor.requireValue(for: argument, description: "disabled, warn, or strict")
            guard let policy = PEXSourceConnectivityPolicy(rawValue: value) else {
                throw PEXError.invalidInput("--source-connectivity requires disabled, warn, or strict")
            }
            sourceConnectivityPolicyOverride = policy
        default:
            throw PEXError.invalidInput("Unknown extract argument '\(argument)'")
        }
    }

    fileprivate func makeProcessProfile() -> PEXProcessProfileReference? {
        ExtractCommand.makeProcessProfile(
            profileID: processProfileID,
            pdkID: pdkID,
            source: processProfileSource,
            requirementID: processRequirementID,
            pdkRoot: pdkRoot,
            primaryDeckPath: primaryDeckPath,
            cornerDeckPaths: cornerDeckPaths,
            requiredViewPaths: requiredViewPaths
        )
    }

    private mutating func recordRequiredView(_ value: String) throws {
        let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw PEXError.invalidInput("--required-view requires <role>=<path>")
        }
        let role = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !role.isEmpty, !path.isEmpty else {
            throw PEXError.invalidInput("--required-view requires a non-empty role and path")
        }
        guard requiredViewPaths[role] == nil else {
            throw PEXError.invalidInput("--required-view was provided more than once for role '\(role)'")
        }
        requiredViewPaths[role] = path
    }

    private mutating func recordCornerDeck(_ value: String) throws {
        let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw PEXError.invalidInput("--corner-deck requires <corner-id>=<deck-path>")
        }
        let cornerID = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cornerID.isEmpty, !path.isEmpty else {
            throw PEXError.invalidInput("--corner-deck requires a non-empty corner ID and deck path")
        }
        guard cornerDeckPaths[cornerID] == nil else {
            throw PEXError.invalidInput("--corner-deck was provided more than once for corner '\(cornerID)'")
        }
        cornerDeckPaths[cornerID] = path
    }

    private mutating func recordCornerTechnology(_ value: String) throws {
        let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw PEXError.invalidInput("--corner-technology requires <corner-id>=<technology-path>")
        }
        let cornerID = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cornerID.isEmpty, !path.isEmpty else {
            throw PEXError.invalidInput("--corner-technology requires a non-empty corner ID and technology path")
        }
        guard technologyByCorner[cornerID] == nil else {
            throw PEXError.invalidInput("--corner-technology was provided more than once for corner '\(cornerID)'")
        }
        technologyByCorner[cornerID] = path
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
        guard let parsed = Double(value), parsed.isFinite, parsed >= 0 else {
            throw PEXError.invalidInput("\(option) requires a finite non-negative numeric value")
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
