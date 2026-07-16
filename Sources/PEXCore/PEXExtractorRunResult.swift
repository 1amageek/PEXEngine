public struct PEXExtractorRunResult: Sendable, Codable, Hashable {
    public struct CornerSummary: Sendable, Codable, Hashable {
        public let cornerID: PEXCornerID
        public let status: PEXRunStatus
        public let netCount: Int
        public let elementCount: Int
        public let rawOutputCount: Int
        public let warningCount: Int
        public let unitSystem: String?
        public let totalGroundCapF: Double?
        public let totalCouplingCapF: Double?
        public let totalCapacitanceF: Double?
        public let totalResistanceOhm: Double?
        public let rawOutputArtifactIDs: [String]
        public let parasiticIRArtifactID: String?
        public let spefRoundTripArtifactID: String?
        public let spiceBackannotationArtifactID: String?
        public let sourceConnectivityArtifactID: String?
        public let failureStage: PEXStage?
        public let failureMessage: String?

        public init(
            cornerID: PEXCornerID,
            status: PEXRunStatus,
            netCount: Int,
            elementCount: Int,
            rawOutputCount: Int,
            warningCount: Int,
            unitSystem: String? = nil,
            totalGroundCapF: Double? = nil,
            totalCouplingCapF: Double? = nil,
            totalCapacitanceF: Double? = nil,
            totalResistanceOhm: Double? = nil,
            rawOutputArtifactIDs: [String] = [],
            parasiticIRArtifactID: String? = nil,
            spefRoundTripArtifactID: String? = nil,
            spiceBackannotationArtifactID: String? = nil,
            sourceConnectivityArtifactID: String? = nil,
            failureStage: PEXStage? = nil,
            failureMessage: String? = nil
        ) {
            self.cornerID = cornerID
            self.status = status
            self.netCount = netCount
            self.elementCount = elementCount
            self.rawOutputCount = rawOutputCount
            self.warningCount = warningCount
            self.unitSystem = unitSystem
            self.totalGroundCapF = totalGroundCapF
            self.totalCouplingCapF = totalCouplingCapF
            self.totalCapacitanceF = totalCapacitanceF
            self.totalResistanceOhm = totalResistanceOhm
            self.rawOutputArtifactIDs = Array(Set(rawOutputArtifactIDs.filter { !$0.isEmpty })).sorted()
            self.parasiticIRArtifactID = parasiticIRArtifactID
            self.spefRoundTripArtifactID = spefRoundTripArtifactID
            self.spiceBackannotationArtifactID = spiceBackannotationArtifactID
            self.sourceConnectivityArtifactID = sourceConnectivityArtifactID
            self.failureStage = failureStage
            self.failureMessage = failureMessage
        }
    }

    public let request: PEXExtractorRunRequest
    public let readiness: PEXExtractorToolReadiness
    public let status: PEXRunStatus
    public let cornerResults: [CornerSummary]
    public let multiCorner: PEXExtractorMultiCornerSummary
    public let artifactIDs: [String]
    public let diagnostics: [PEXExtractorDiagnostic]

    public init(
        request: PEXExtractorRunRequest,
        readiness: PEXExtractorToolReadiness,
        status: PEXRunStatus,
        cornerResults: [CornerSummary],
        artifactIDs: [String],
        multiCorner: PEXExtractorMultiCornerSummary? = nil,
        diagnostics: [PEXExtractorDiagnostic] = []
    ) {
        self.request = request
        self.readiness = readiness
        self.status = status
        self.cornerResults = cornerResults
        self.multiCorner = multiCorner ?? PEXExtractorMultiCornerSummary(
            cornerResults: cornerResults,
            comparisonBasis: .unknown
        )
        self.artifactIDs = Array(Set(artifactIDs.filter { !$0.isEmpty })).sorted()
        self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case request
        case readiness
        case status
        case cornerResults
        case multiCorner
        case artifactIDs
        case diagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let request = try container.decode(PEXExtractorRunRequest.self, forKey: .request)
        let readiness = try container.decode(PEXExtractorToolReadiness.self, forKey: .readiness)
        let status = try container.decode(PEXRunStatus.self, forKey: .status)
        let cornerResults = try container.decode([CornerSummary].self, forKey: .cornerResults)
        let artifactIDs = try container.decode([String].self, forKey: .artifactIDs)
        let diagnostics = try container.decode([PEXExtractorDiagnostic].self, forKey: .diagnostics)
        let multiCorner = try container.decode(PEXExtractorMultiCornerSummary.self, forKey: .multiCorner)

        self.init(
            request: request,
            readiness: readiness,
            status: status,
            cornerResults: cornerResults,
            artifactIDs: artifactIDs,
            multiCorner: multiCorner,
            diagnostics: diagnostics
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(request, forKey: .request)
        try container.encode(readiness, forKey: .readiness)
        try container.encode(status, forKey: .status)
        try container.encode(cornerResults, forKey: .cornerResults)
        try container.encode(multiCorner, forKey: .multiCorner)
        try container.encode(artifactIDs, forKey: .artifactIDs)
        try container.encode(diagnostics, forKey: .diagnostics)
    }
}
