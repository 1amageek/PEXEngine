import Foundation

/// Persisted PEX configuration shared between CircuitStudio and the standalone `pexengine` CLI.
public struct PEXProjectConfig: Sendable, Codable, Hashable {
    public static let currentVersion = 1

    public struct InputPaths: Sendable, Codable, Hashable {
        public var layout: String
        public var netlist: String
        public var technology: String
        public var technologyByCorner: [String: String]

        public init(
            layout: String = "top.oas",
            netlist: String = "top.cir",
            technology: String = "tech.json",
            technologyByCorner: [String: String] = [:]
        ) {
            self.layout = layout
            self.netlist = netlist
            self.technology = technology
            self.technologyByCorner = technologyByCorner
        }

        private enum CodingKeys: String, CodingKey {
            case layout
            case netlist
            case technology
            case technologyByCorner
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                layout: try container.decode(String.self, forKey: .layout),
                netlist: try container.decode(String.self, forKey: .netlist),
                technology: try container.decode(String.self, forKey: .technology),
                technologyByCorner: try container.decode(
                    [String: String].self,
                    forKey: .technologyByCorner
                )
            )
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
        public var sourceConnectivityPolicy: PEXSourceConnectivityPolicy

        public init(
            includeCouplingCaps: Bool = true,
            minCapacitanceF: Double? = nil,
            minResistanceOhm: Double? = nil,
            maxParallelJobs: Int = 2,
            strictValidation: Bool = false,
            sourceConnectivityPolicy: PEXSourceConnectivityPolicy = .warn
        ) {
            self.includeCouplingCaps = includeCouplingCaps
            self.minCapacitanceF = minCapacitanceF
            self.minResistanceOhm = minResistanceOhm
            self.maxParallelJobs = maxParallelJobs
            self.strictValidation = strictValidation
            self.sourceConnectivityPolicy = sourceConnectivityPolicy
        }

        private enum CodingKeys: String, CodingKey {
            case includeCouplingCaps
            case minCapacitanceF
            case minResistanceOhm
            case maxParallelJobs
            case strictValidation
            case sourceConnectivityPolicy
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                includeCouplingCaps: try container.decode(Bool.self, forKey: .includeCouplingCaps),
                minCapacitanceF: try container.decodeIfPresent(Double.self, forKey: .minCapacitanceF),
                minResistanceOhm: try container.decodeIfPresent(Double.self, forKey: .minResistanceOhm),
                maxParallelJobs: try container.decode(Int.self, forKey: .maxParallelJobs),
                strictValidation: try container.decode(Bool.self, forKey: .strictValidation),
                sourceConnectivityPolicy: try container.decode(PEXSourceConnectivityPolicy.self, forKey: .sourceConnectivityPolicy)
            )
        }
    }

    public var version: Int
    public var enabled: Bool
    public var executablePath: String?
    public var topCell: String
    public var backendID: String
    public var processProfile: PEXProcessProfileReference?
    public var corners: [String]
    public var inputs: InputPaths
    public var output: OutputPaths
    public var options: Options

    public init(
        version: Int = Self.currentVersion,
        enabled: Bool = true,
        executablePath: String? = nil,
        topCell: String = "TOP",
        backendID: String = "",
        processProfile: PEXProcessProfileReference? = nil,
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
        self.processProfile = processProfile
        self.corners = corners
        self.inputs = inputs
        self.output = output
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported PEX project configuration version \(version)."
            )
        }
        self.version = version
        self.enabled = try container.decode(Bool.self, forKey: .enabled)
        self.executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        self.topCell = try container.decode(String.self, forKey: .topCell)
        self.backendID = try container.decode(String.self, forKey: .backendID)
        self.processProfile = try container.decodeIfPresent(PEXProcessProfileReference.self, forKey: .processProfile)
        self.corners = try container.decode([String].self, forKey: .corners)
        self.inputs = try container.decode(InputPaths.self, forKey: .inputs)
        self.output = try container.decode(OutputPaths.self, forKey: .output)
        self.options = try container.decode(Options.self, forKey: .options)
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
