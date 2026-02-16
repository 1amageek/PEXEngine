import Foundation

/// Persisted PEX configuration shared between CircuitStudio and the standalone `pexengine` CLI.
public struct PEXProjectConfig: Sendable, Codable, Hashable {
    public struct InputPaths: Sendable, Codable, Hashable {
        public var layout: String
        public var netlist: String
        public var technology: String

        public init(
            layout: String = "top.oas",
            netlist: String = "top.cir",
            technology: String = "tech.json"
        ) {
            self.layout = layout
            self.netlist = netlist
            self.technology = technology
        }
    }

    public struct OutputPaths: Sendable, Codable, Hashable {
        public var workspace: String

        public init(workspace: String = ".xcircuite/pex/runs") {
            self.workspace = workspace
        }
    }

    public struct Options: Sendable, Codable, Hashable {
        public var includeCouplingCaps: Bool
        public var minCapacitanceF: Double?
        public var minResistanceOhm: Double?
        public var maxParallelJobs: Int
        public var strictValidation: Bool

        public init(
            includeCouplingCaps: Bool = true,
            minCapacitanceF: Double? = nil,
            minResistanceOhm: Double? = nil,
            maxParallelJobs: Int = 2,
            strictValidation: Bool = false
        ) {
            self.includeCouplingCaps = includeCouplingCaps
            self.minCapacitanceF = minCapacitanceF
            self.minResistanceOhm = minResistanceOhm
            self.maxParallelJobs = maxParallelJobs
            self.strictValidation = strictValidation
        }
    }

    public var version: Int
    public var enabled: Bool
    public var executablePath: String?
    public var topCell: String
    public var backendID: String
    public var corners: [String]
    public var inputs: InputPaths
    public var output: OutputPaths
    public var options: Options

    public init(
        version: Int = 1,
        enabled: Bool = true,
        executablePath: String? = nil,
        topCell: String = "TOP",
        backendID: String = "mock",
        corners: [String] = ["tt_25c_1v0"],
        inputs: InputPaths = InputPaths(),
        output: OutputPaths = OutputPaths(),
        options: Options = Options()
    ) {
        self.version = version
        self.enabled = enabled
        self.executablePath = executablePath
        self.topCell = topCell
        self.backendID = backendID
        self.corners = corners
        self.inputs = inputs
        self.output = output
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        self.topCell = try container.decodeIfPresent(String.self, forKey: .topCell) ?? "TOP"
        self.backendID = try container.decodeIfPresent(String.self, forKey: .backendID) ?? "mock"
        self.corners = try container.decodeIfPresent([String].self, forKey: .corners) ?? ["tt_25c_1v0"]
        self.inputs = try container.decodeIfPresent(InputPaths.self, forKey: .inputs) ?? InputPaths()
        self.output = try container.decodeIfPresent(OutputPaths.self, forKey: .output) ?? OutputPaths()
        self.options = try container.decodeIfPresent(Options.self, forKey: .options) ?? Options()
    }

    public var normalizedCorners: [String] {
        let filtered = corners.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if filtered.isEmpty {
            return ["tt_25c_1v0"]
        }
        return filtered
    }
}
