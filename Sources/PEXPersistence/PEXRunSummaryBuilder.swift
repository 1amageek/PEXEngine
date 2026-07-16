import Foundation
import PEXCore

public struct PEXRunSummaryBuilder: Sendable {
    public init() {}

    public func build(
        manifestURL: URL,
        topNets: Int = 10,
        cornerFilter: PEXCornerID? = nil
    ) throws -> PEXRunSummaryReport {
        let resolver = try PEXArtifactResolver(manifestURL: manifestURL)
        return try build(
            resolver: resolver,
            topNets: topNets,
            cornerFilter: cornerFilter
        )
    }

    public func build(
        resolver: PEXArtifactResolver,
        topNets: Int = 10,
        cornerFilter: PEXCornerID? = nil
    ) throws -> PEXRunSummaryReport {
        guard topNets > 0 else {
            throw PEXError.invalidInput("topNets must be a positive integer")
        }

        let manifest = resolver.manifest
        let completeness = resolver.completenessReport()
        let cornersToProcess: [PEXArtifactCorner]
        if let cornerFilter {
            cornersToProcess = manifest.corners.filter { $0.cornerID == cornerFilter }
            if cornersToProcess.isEmpty {
                throw PEXError.invalidInput("Corner '\(cornerFilter.value)' not found in run")
            }
        } else {
            cornersToProcess = manifest.corners
        }

        let cornerSummaries = cornersToProcess.map { entry in
            cornerSummary(
                entry: entry,
                resolver: resolver,
                topNets: topNets
            )
        }

        return PEXRunSummaryReport(
            manifestURL: resolver.manifestURL,
            completeness: completeness,
            summary: PEXRunSummary(
                runID: manifest.runID.description,
                status: manifest.status.rawValue,
                backendID: manifest.backendID,
                corners: cornerSummaries,
                multiCorner: multiCornerSummary(
                    corners: cornerSummaries,
                    topNets: topNets,
                    comparisonBasis: manifest.extractorRun?.multiCorner.comparisonBasis ?? .unknown
                )
            )
        )
    }

    private func cornerSummary(
        entry: PEXArtifactCorner,
        resolver: PEXArtifactResolver,
        topNets: Int
    ) -> PEXCornerParasiticSummary {
        let rawArtifactIDs = resolver.records(kind: .rawOutput, cornerID: entry.cornerID, availability: .available).map { $0.id.rawValue }
        let irArtifactID = resolver.records(kind: .parasiticIR, cornerID: entry.cornerID, availability: .available).first?.id.rawValue
        let spefRoundTripArtifactID = resolver.records(kind: .spefRoundTrip, cornerID: entry.cornerID, availability: .available).first?.id.rawValue
        let spiceBackannotationArtifactID = resolver.records(kind: .spiceBackannotation, cornerID: entry.cornerID, availability: .available).first?.id.rawValue
        guard irArtifactID != nil else {
            return PEXCornerParasiticSummary(
                cornerID: entry.cornerID.value,
                status: "error",
                netCount: 0,
                elementCount: 0,
                unitSystem: "canonical",
                totalGroundCapF: 0,
                totalCouplingCapF: 0,
                totalCapacitanceF: 0,
                totalResistanceOhm: 0,
                rawOutputArtifactIDs: rawArtifactIDs,
                parasiticIRArtifactID: nil,
                spefRoundTripArtifactID: spefRoundTripArtifactID,
                spiceBackannotationArtifactID: spiceBackannotationArtifactID,
                topNets: [],
                diagnostics: [
                    PEXRunSummaryDiagnostic(
                        severity: "error",
                        code: "PEX_SUMMARY_IR_MISSING",
                        message: "Corner \(entry.cornerID.value) has no available parasitic IR artifact; summary values are unavailable."
                    ),
                ]
            )
        }

        do {
            let ir = try resolver.loadIR(cornerID: entry.cornerID)
            let topNetEntries = ir.nets
                .sorted { lhs, rhs in
                    (lhs.totalGroundCapF + lhs.totalCouplingCapF) > (rhs.totalGroundCapF + rhs.totalCouplingCapF)
                }
                .prefix(topNets)
                .map { net in
                    PEXNetParasiticSummary(
                        name: net.name.value,
                        groundCapF: net.totalGroundCapF,
                        couplingCapF: net.totalCouplingCapF,
                        resistanceOhm: net.totalResistanceOhm,
                        nodeCount: net.nodes.count
                    )
                }
            return PEXCornerParasiticSummary(
                cornerID: entry.cornerID.value,
                status: entry.status.rawValue,
                netCount: ir.nets.count,
                elementCount: ir.elements.count,
                unitSystem: "canonical",
                totalGroundCapF: totalGroundCapF(ir),
                totalCouplingCapF: totalCouplingCapF(ir),
                totalCapacitanceF: totalGroundCapF(ir) + totalCouplingCapF(ir),
                totalResistanceOhm: totalResistanceOhm(ir),
                rawOutputArtifactIDs: rawArtifactIDs,
                parasiticIRArtifactID: irArtifactID,
                spefRoundTripArtifactID: spefRoundTripArtifactID,
                spiceBackannotationArtifactID: spiceBackannotationArtifactID,
                topNets: topNetEntries,
                diagnostics: []
            )
        } catch {
            return PEXCornerParasiticSummary(
                cornerID: entry.cornerID.value,
                status: "error",
                netCount: 0,
                elementCount: 0,
                unitSystem: "canonical",
                totalGroundCapF: 0,
                totalCouplingCapF: 0,
                totalCapacitanceF: 0,
                totalResistanceOhm: 0,
                rawOutputArtifactIDs: rawArtifactIDs,
                parasiticIRArtifactID: irArtifactID,
                spefRoundTripArtifactID: spefRoundTripArtifactID,
                spiceBackannotationArtifactID: spiceBackannotationArtifactID,
                topNets: [],
                diagnostics: [
                    PEXRunSummaryDiagnostic(
                        severity: "error",
                        code: "PEX_SUMMARY_IR_LOAD_FAILED",
                        message: String(describing: error)
                    ),
                ]
            )
        }
    }

    private func totalGroundCapF(_ ir: ParasiticIR) -> Double {
        ir.nets.reduce(0) { $0 + $1.totalGroundCapF }
    }

    private func totalCouplingCapF(_ ir: ParasiticIR) -> Double {
        ir.nets.reduce(0) { $0 + $1.totalCouplingCapF }
    }

    private func totalResistanceOhm(_ ir: ParasiticIR) -> Double {
        ir.nets.reduce(0) { $0 + $1.totalResistanceOhm }
    }

    private func multiCornerSummary(
        corners: [PEXCornerParasiticSummary],
        topNets: Int,
        comparisonBasis: PEXExtractorMultiCornerComparisonBasis
    ) -> PEXMultiCornerParasiticSummary {
        let successfulCorners = corners.filter { $0.status == PEXRunStatus.success.rawValue }
        let successfulCornerIDs = successfulCorners.map(\.cornerID)
        let failedCornerIDs = corners
            .filter { $0.status != PEXRunStatus.success.rawValue }
            .map(\.cornerID)
        let netSpreads = topNetSpreads(
            corners: successfulCorners,
            successfulCornerIDs: successfulCornerIDs,
            topNets: topNets
        )
        let diagnostics = multiCornerDiagnostics(
            corners: corners,
            failedCornerIDs: failedCornerIDs,
            comparableCornerCount: successfulCorners.count
        )

        return PEXMultiCornerParasiticSummary(
            cornerCount: corners.count,
            successfulCornerCount: successfulCorners.count,
            failedCornerCount: failedCornerIDs.count,
            failedCornerIDs: failedCornerIDs,
            comparisonBasis: comparisonBasis,
            totalCapacitance: metricSpread(
                metric: "totalCapacitanceF",
                unit: "F",
                values: successfulCorners.map { ($0.cornerID, $0.totalCapacitanceF) }
            ),
            totalResistance: metricSpread(
                metric: "totalResistanceOhm",
                unit: "ohm",
                values: successfulCorners.map { ($0.cornerID, $0.totalResistanceOhm) }
            ),
            topNetSpreads: netSpreads,
            diagnostics: diagnostics
        )
    }

    private func topNetSpreads(
        corners: [PEXCornerParasiticSummary],
        successfulCornerIDs: [String],
        topNets: Int
    ) -> [PEXNetCornerSpreadSummary] {
        let netNames = Array(Set(corners.flatMap { $0.topNets.map(\.name) })).sorted()
        let spreads = netNames.map { netName in
            let entries = corners.compactMap { corner -> (cornerID: String, net: PEXNetParasiticSummary)? in
                guard let net = corner.topNets.first(where: { $0.name == netName }) else {
                    return nil
                }
                return (corner.cornerID, net)
            }
            let observedCornerIDs = entries.map(\.cornerID)
            let missingCornerIDs = successfulCornerIDs.filter { !observedCornerIDs.contains($0) }
            return PEXNetCornerSpreadSummary(
                netName: netName,
                observedCornerIDs: observedCornerIDs,
                missingCornerIDs: missingCornerIDs,
                totalCapacitance: metricSpread(
                    metric: "netTotalCapacitanceF",
                    unit: "F",
                    values: entries.map { ($0.cornerID, $0.net.groundCapF + $0.net.couplingCapF) }
                ),
                resistance: metricSpread(
                    metric: "netResistanceOhm",
                    unit: "ohm",
                    values: entries.map { ($0.cornerID, $0.net.resistanceOhm) }
                )
            )
        }

        return Array(spreads.sorted { lhs, rhs in
            if lhs.totalCapacitance.spread == rhs.totalCapacitance.spread {
                return (lhs.totalCapacitance.maxValue ?? 0) > (rhs.totalCapacitance.maxValue ?? 0)
            }
            return lhs.totalCapacitance.spread > rhs.totalCapacitance.spread
        }.prefix(topNets))
    }

    private func metricSpread(
        metric: String,
        unit: String,
        values: [(cornerID: String, value: Double)]
    ) -> PEXCornerMetricSpreadSummary {
        let finiteValues = values.filter { $0.value.isFinite }
        guard !finiteValues.isEmpty else {
            return PEXCornerMetricSpreadSummary(
                metric: metric,
                unit: unit,
                observedCornerCount: 0,
                minCornerID: nil,
                minValue: nil,
                maxCornerID: nil,
                maxValue: nil,
                spread: 0,
                relativeSpread: nil
            )
        }

        var minEntry = finiteValues[0]
        var maxEntry = finiteValues[0]
        for entry in finiteValues.dropFirst() {
            if entry.value < minEntry.value {
                minEntry = entry
            }
            if entry.value > maxEntry.value {
                maxEntry = entry
            }
        }
        let minValue = minEntry.value
        let maxValue = maxEntry.value
        let spread = maxValue - minValue
        let relativeSpread = minValue == 0 ? nil : spread / abs(minValue)

        return PEXCornerMetricSpreadSummary(
            metric: metric,
            unit: unit,
            observedCornerCount: finiteValues.count,
            minCornerID: minEntry.cornerID,
            minValue: minEntry.value,
            maxCornerID: maxEntry.cornerID,
            maxValue: maxEntry.value,
            spread: spread,
            relativeSpread: relativeSpread
        )
    }

    private func multiCornerDiagnostics(
        corners: [PEXCornerParasiticSummary],
        failedCornerIDs: [String],
        comparableCornerCount: Int
    ) -> [PEXRunSummaryDiagnostic] {
        var diagnostics = corners.flatMap(\.diagnostics)
        if !failedCornerIDs.isEmpty {
            diagnostics.append(
                PEXRunSummaryDiagnostic(
                    severity: "error",
                    code: "PEX_MULTI_CORNER_FAILED_CORNERS",
                    message: "PEX failed or was incomplete for corners: \(failedCornerIDs.joined(separator: ", "))."
                )
            )
        }
        if corners.count > 1 && comparableCornerCount < 2 {
            diagnostics.append(
                PEXRunSummaryDiagnostic(
                    severity: "warning",
                    code: "PEX_MULTI_CORNER_NOT_COMPARABLE",
                    message: "Fewer than two successful corners are available for spread analysis."
                )
            )
        }
        return diagnostics
    }
}

public struct PEXRunSummaryReport: Sendable, Codable, Hashable {
    public let manifestURL: URL
    public let completeness: PEXArtifactCompletenessReport
    public let summary: PEXRunSummary

    public init(
        manifestURL: URL,
        completeness: PEXArtifactCompletenessReport,
        summary: PEXRunSummary
    ) {
        self.manifestURL = manifestURL
        self.completeness = completeness
        self.summary = summary
    }
}

public struct PEXRunSummary: Sendable, Codable, Hashable {
    public let runID: String
    public let status: String
    public let backendID: String
    public let corners: [PEXCornerParasiticSummary]
    public let multiCorner: PEXMultiCornerParasiticSummary

    public init(
        runID: String,
        status: String,
        backendID: String,
        corners: [PEXCornerParasiticSummary],
        multiCorner: PEXMultiCornerParasiticSummary? = nil
    ) {
        self.runID = runID
        self.status = status
        self.backendID = backendID
        self.corners = corners
        self.multiCorner = multiCorner ?? PEXMultiCornerParasiticSummary(corners: corners)
    }

    private enum CodingKeys: String, CodingKey {
        case runID
        case status
        case backendID
        case corners
        case multiCorner
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let runID = try container.decode(String.self, forKey: .runID)
        let status = try container.decode(String.self, forKey: .status)
        let backendID = try container.decode(String.self, forKey: .backendID)
        let corners = try container.decode([PEXCornerParasiticSummary].self, forKey: .corners)
        let multiCorner = try container.decode(PEXMultiCornerParasiticSummary.self, forKey: .multiCorner)

        self.init(
            runID: runID,
            status: status,
            backendID: backendID,
            corners: corners,
            multiCorner: multiCorner
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runID, forKey: .runID)
        try container.encode(status, forKey: .status)
        try container.encode(backendID, forKey: .backendID)
        try container.encode(corners, forKey: .corners)
        try container.encode(multiCorner, forKey: .multiCorner)
    }
}

public struct PEXMultiCornerParasiticSummary: Sendable, Codable, Hashable {
    public let comparisonBasis: PEXExtractorMultiCornerComparisonBasis
    public let cornerCount: Int
    public let successfulCornerCount: Int
    public let failedCornerCount: Int
    public let failedCornerIDs: [String]
    public let totalCapacitance: PEXCornerMetricSpreadSummary
    public let totalResistance: PEXCornerMetricSpreadSummary
    public let topNetSpreads: [PEXNetCornerSpreadSummary]
    public let diagnostics: [PEXRunSummaryDiagnostic]

    public var worstCapacitanceCornerID: String? {
        totalCapacitance.maxCornerID
    }

    public var worstResistanceCornerID: String? {
        totalResistance.maxCornerID
    }

    public init(
        cornerCount: Int,
        successfulCornerCount: Int,
        failedCornerCount: Int,
        failedCornerIDs: [String],
        comparisonBasis: PEXExtractorMultiCornerComparisonBasis = .unknown,
        totalCapacitance: PEXCornerMetricSpreadSummary,
        totalResistance: PEXCornerMetricSpreadSummary,
        topNetSpreads: [PEXNetCornerSpreadSummary],
        diagnostics: [PEXRunSummaryDiagnostic]
    ) {
        self.comparisonBasis = comparisonBasis
        self.cornerCount = cornerCount
        self.successfulCornerCount = successfulCornerCount
        self.failedCornerCount = failedCornerCount
        self.failedCornerIDs = Array(Set(failedCornerIDs.filter { !$0.isEmpty })).sorted()
        self.totalCapacitance = totalCapacitance
        self.totalResistance = totalResistance
        self.topNetSpreads = topNetSpreads
        self.diagnostics = diagnostics
    }

    public init(corners: [PEXCornerParasiticSummary]) {
        let successfulCorners = corners.filter { $0.status == PEXRunStatus.success.rawValue }
        let failedCornerIDs = corners
            .filter { $0.status != PEXRunStatus.success.rawValue }
            .map(\.cornerID)
        let totalCapacitance = Self.metricSpread(
            metric: "totalCapacitanceF",
            unit: "F",
            values: successfulCorners.map { ($0.cornerID, $0.totalCapacitanceF) }
        )
        let totalResistance = Self.metricSpread(
            metric: "totalResistanceOhm",
            unit: "ohm",
            values: successfulCorners.map { ($0.cornerID, $0.totalResistanceOhm) }
        )

        self.init(
            cornerCount: corners.count,
            successfulCornerCount: successfulCorners.count,
            failedCornerCount: failedCornerIDs.count,
            failedCornerIDs: failedCornerIDs,
            comparisonBasis: .unknown,
            totalCapacitance: totalCapacitance,
            totalResistance: totalResistance,
            topNetSpreads: [],
            diagnostics: corners.flatMap(\.diagnostics)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case comparisonBasis
        case cornerCount
        case successfulCornerCount
        case failedCornerCount
        case failedCornerIDs
        case totalCapacitance
        case totalResistance
        case topNetSpreads
        case diagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cornerCount: try container.decode(Int.self, forKey: .cornerCount),
            successfulCornerCount: try container.decode(Int.self, forKey: .successfulCornerCount),
            failedCornerCount: try container.decode(Int.self, forKey: .failedCornerCount),
            failedCornerIDs: try container.decode([String].self, forKey: .failedCornerIDs),
            comparisonBasis: try container.decodeIfPresent(
                PEXExtractorMultiCornerComparisonBasis.self,
                forKey: .comparisonBasis
            ) ?? .unknown,
            totalCapacitance: try container.decode(
                PEXCornerMetricSpreadSummary.self,
                forKey: .totalCapacitance
            ),
            totalResistance: try container.decode(
                PEXCornerMetricSpreadSummary.self,
                forKey: .totalResistance
            ),
            topNetSpreads: try container.decode([PEXNetCornerSpreadSummary].self, forKey: .topNetSpreads),
            diagnostics: try container.decode([PEXRunSummaryDiagnostic].self, forKey: .diagnostics)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(comparisonBasis, forKey: .comparisonBasis)
        try container.encode(cornerCount, forKey: .cornerCount)
        try container.encode(successfulCornerCount, forKey: .successfulCornerCount)
        try container.encode(failedCornerCount, forKey: .failedCornerCount)
        try container.encode(failedCornerIDs, forKey: .failedCornerIDs)
        try container.encode(totalCapacitance, forKey: .totalCapacitance)
        try container.encode(totalResistance, forKey: .totalResistance)
        try container.encode(topNetSpreads, forKey: .topNetSpreads)
        try container.encode(diagnostics, forKey: .diagnostics)
    }

    private static func metricSpread(
        metric: String,
        unit: String,
        values: [(cornerID: String, value: Double)]
    ) -> PEXCornerMetricSpreadSummary {
        let finiteValues = values.filter { $0.value.isFinite }
        guard !finiteValues.isEmpty else {
            return PEXCornerMetricSpreadSummary(
                metric: metric,
                unit: unit,
                observedCornerCount: 0,
                minCornerID: nil,
                minValue: nil,
                maxCornerID: nil,
                maxValue: nil,
                spread: 0,
                relativeSpread: nil
            )
        }
        var minEntry = finiteValues[0]
        var maxEntry = finiteValues[0]
        for entry in finiteValues.dropFirst() {
            if entry.value < minEntry.value {
                minEntry = entry
            }
            if entry.value > maxEntry.value {
                maxEntry = entry
            }
        }
        let minValue = minEntry.value
        let maxValue = maxEntry.value
        let spread = maxValue - minValue
        return PEXCornerMetricSpreadSummary(
            metric: metric,
            unit: unit,
            observedCornerCount: finiteValues.count,
            minCornerID: minEntry.cornerID,
            minValue: minEntry.value,
            maxCornerID: maxEntry.cornerID,
            maxValue: maxEntry.value,
            spread: spread,
            relativeSpread: minValue == 0 ? nil : spread / abs(minValue)
        )
    }
}

public struct PEXCornerMetricSpreadSummary: Sendable, Codable, Hashable {
    public let metric: String
    public let unit: String
    public let observedCornerCount: Int
    public let minCornerID: String?
    public let minValue: Double?
    public let maxCornerID: String?
    public let maxValue: Double?
    public let spread: Double
    public let relativeSpread: Double?

    public init(
        metric: String,
        unit: String,
        observedCornerCount: Int,
        minCornerID: String?,
        minValue: Double?,
        maxCornerID: String?,
        maxValue: Double?,
        spread: Double,
        relativeSpread: Double?
    ) {
        self.metric = metric
        self.unit = unit
        self.observedCornerCount = observedCornerCount
        self.minCornerID = minCornerID
        self.minValue = minValue
        self.maxCornerID = maxCornerID
        self.maxValue = maxValue
        self.spread = spread
        self.relativeSpread = relativeSpread
    }
}

public struct PEXNetCornerSpreadSummary: Sendable, Codable, Hashable {
    public let netName: String
    public let observedCornerIDs: [String]
    public let missingCornerIDs: [String]
    public let totalCapacitance: PEXCornerMetricSpreadSummary
    public let resistance: PEXCornerMetricSpreadSummary

    public init(
        netName: String,
        observedCornerIDs: [String],
        missingCornerIDs: [String],
        totalCapacitance: PEXCornerMetricSpreadSummary,
        resistance: PEXCornerMetricSpreadSummary
    ) {
        self.netName = netName
        self.observedCornerIDs = Array(Set(observedCornerIDs.filter { !$0.isEmpty })).sorted()
        self.missingCornerIDs = Array(Set(missingCornerIDs.filter { !$0.isEmpty })).sorted()
        self.totalCapacitance = totalCapacitance
        self.resistance = resistance
    }
}

public struct PEXCornerParasiticSummary: Sendable, Codable, Hashable {
    public let cornerID: String
    public let status: String
    public let netCount: Int
    public let elementCount: Int
    public let unitSystem: String
    public let totalGroundCapF: Double
    public let totalCouplingCapF: Double
    public let totalCapacitanceF: Double
    public let totalResistanceOhm: Double
    public let rawOutputArtifactIDs: [String]
    public let parasiticIRArtifactID: String?
    public let spefRoundTripArtifactID: String?
    public let spiceBackannotationArtifactID: String?
    public let topNets: [PEXNetParasiticSummary]
    public let diagnostics: [PEXRunSummaryDiagnostic]

    public init(
        cornerID: String,
        status: String,
        netCount: Int,
        elementCount: Int,
        unitSystem: String = "canonical",
        totalGroundCapF: Double = 0,
        totalCouplingCapF: Double = 0,
        totalCapacitanceF: Double = 0,
        totalResistanceOhm: Double = 0,
        rawOutputArtifactIDs: [String] = [],
        parasiticIRArtifactID: String? = nil,
        spefRoundTripArtifactID: String? = nil,
        spiceBackannotationArtifactID: String? = nil,
        topNets: [PEXNetParasiticSummary],
        diagnostics: [PEXRunSummaryDiagnostic] = []
    ) {
        self.cornerID = cornerID
        self.status = status
        self.netCount = netCount
        self.elementCount = elementCount
        self.unitSystem = unitSystem
        self.totalGroundCapF = totalGroundCapF
        self.totalCouplingCapF = totalCouplingCapF
        self.totalCapacitanceF = totalCapacitanceF
        self.totalResistanceOhm = totalResistanceOhm
        self.rawOutputArtifactIDs = Array(Set(rawOutputArtifactIDs.filter { !$0.isEmpty })).sorted()
        self.parasiticIRArtifactID = parasiticIRArtifactID
        self.spefRoundTripArtifactID = spefRoundTripArtifactID
        self.spiceBackannotationArtifactID = spiceBackannotationArtifactID
        self.topNets = topNets
        self.diagnostics = diagnostics
    }
}

public struct PEXNetParasiticSummary: Sendable, Codable, Hashable {
    public let name: String
    public let groundCapF: Double
    public let couplingCapF: Double
    public let resistanceOhm: Double
    public let nodeCount: Int

    public init(
        name: String,
        groundCapF: Double,
        couplingCapF: Double,
        resistanceOhm: Double,
        nodeCount: Int
    ) {
        self.name = name
        self.groundCapF = groundCapF
        self.couplingCapF = couplingCapF
        self.resistanceOhm = resistanceOhm
        self.nodeCount = nodeCount
    }
}

public struct PEXRunSummaryDiagnostic: Sendable, Codable, Hashable {
    public let severity: String
    public let code: String
    public let message: String

    public init(severity: String, code: String, message: String) {
        self.severity = severity
        self.code = code
        self.message = message
    }
}
