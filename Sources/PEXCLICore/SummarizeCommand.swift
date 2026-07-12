import Foundation
import PEXEngine

public struct SummarizeCommand: Sendable {
    public let runPath: URL
    public let topNets: Int
    public let cornerFilter: PEXCornerID?
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        var runPathStr: String?
        var topN = 10
        var corner: String?
        var json = false
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--run":
                i += 1
                guard i < arguments.count else {
                    throw PEXError.invalidInput("--run requires a path argument")
                }
                runPathStr = arguments[i]
            case "--top-nets":
                i += 1
                guard i < arguments.count, let n = Int(arguments[i]), n > 0 else {
                    throw PEXError.invalidInput("--top-nets requires a positive integer")
                }
                topN = n
            case "--corner":
                i += 1
                guard i < arguments.count else {
                    throw PEXError.invalidInput("--corner requires an ID argument")
                }
                corner = arguments[i]
            case "--json":
                json = true
            default:
                throw PEXError.invalidInput("Unknown summarize argument '\(arguments[i])'")
            }
            i += 1
        }

        guard let runPathStr else {
            throw PEXError.invalidInput("--run <path> is required for summarize command")
        }

        self.runPath = URL(filePath: runPathStr)
        self.topNets = topN
        self.cornerFilter = corner.map { PEXCornerID($0) }
        self.jsonOutput = json
    }

    public func run() async throws {
        let output = try buildSummary()
        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let jsonData = try encoder.encode(output)
            print(String(data: jsonData, encoding: .utf8) ?? "{}")
        } else {
            let summary = output.summary
            print("Run: \(summary.runID)")
            print("Status: \(summary.status)")
            print("Backend: \(summary.backendID)")
            print("Corners: \(summary.corners.count)")
            print("Comparison basis: \(summary.multiCorner.comparisonBasis.rawValue)")
            print("Successful corners: \(summary.multiCorner.successfulCornerCount)")
            print("Failed corners: \(summary.multiCorner.failedCornerCount)")
            if !summary.multiCorner.failedCornerIDs.isEmpty {
                print("Failed corner IDs: \(summary.multiCorner.failedCornerIDs.joined(separator: ", "))")
            }
            if let worstCorner = summary.multiCorner.worstCapacitanceCornerID {
                print("Worst capacitance corner: \(worstCorner)")
                print("Capacitance spread: \(formatEngineering(summary.multiCorner.totalCapacitance.spread))F")
            }
            if let worstCorner = summary.multiCorner.worstResistanceCornerID {
                print("Worst resistance corner: \(worstCorner)")
                print("Resistance spread: \(formatEngineering(summary.multiCorner.totalResistance.spread))Ohm")
            }
            print("")

            for cs in summary.corners {
                print("Corner: \(cs.cornerID) (\(cs.status))")
                print("  Nets: \(cs.netCount), Elements: \(cs.elementCount)")
                print("  Totals: gnd=\(formatEngineering(cs.totalGroundCapF))F cc=\(formatEngineering(cs.totalCouplingCapF))F total=\(formatEngineering(cs.totalCapacitanceF))F R=\(formatEngineering(cs.totalResistanceOhm))Ohm")
                print("  Units: \(cs.unitSystem)")
                if let irArtifactID = cs.parasiticIRArtifactID {
                    print("  ParasiticIR: \(irArtifactID)")
                }
                if let spefArtifactID = cs.spefRoundTripArtifactID {
                    print("  SPEF round-trip: \(spefArtifactID)")
                }
                if let spiceArtifactID = cs.spiceBackannotationArtifactID {
                    print("  SPICE backannotation: \(spiceArtifactID)")
                }
                if !cs.topNets.isEmpty {
                    print("  Top \(cs.topNets.count) nets by capacitance:")
                    for net in cs.topNets {
                        print("    \(net.name): gnd=\(formatEngineering(net.groundCapF))F cc=\(formatEngineering(net.couplingCapF))F R=\(formatEngineering(net.resistanceOhm))Ohm")
                    }
                }
                print("")
            }

            if !summary.multiCorner.topNetSpreads.isEmpty {
                print("Top multi-corner net spreads:")
                for net in summary.multiCorner.topNetSpreads {
                    print("  \(net.netName): C spread=\(formatEngineering(net.totalCapacitance.spread))F R spread=\(formatEngineering(net.resistance.spread))Ohm")
                }
                print("")
            }
        }
    }

    func buildSummary() throws -> PEXRunSummaryReport {
        let manifestURL = resolveManifestURL()
        return try PEXRunSummaryBuilder().build(
            manifestURL: manifestURL,
            topNets: topNets,
            cornerFilter: cornerFilter
        )
    }

    func formatEngineering(_ value: Double) -> String {
        if value == 0 { return "0" }
        let absValue = abs(value)
        let sign = value < 0 ? "-" : ""
        if absValue >= 1e9 { return "\(sign)\(String(format: "%.3f", absValue / 1e9))G" }
        if absValue >= 1e6 { return "\(sign)\(String(format: "%.3f", absValue / 1e6))M" }
        if absValue >= 1e3 { return "\(sign)\(String(format: "%.3f", absValue / 1e3))k" }
        if absValue >= 1 { return "\(sign)\(String(format: "%.3f", absValue))" }
        if absValue >= 1e-3 { return "\(sign)\(String(format: "%.3f", absValue * 1e3))m" }
        if absValue >= 1e-6 { return "\(sign)\(String(format: "%.3f", absValue * 1e6))u" }
        if absValue >= 1e-9 { return "\(sign)\(String(format: "%.3f", absValue * 1e9))n" }
        if absValue >= 1e-12 { return "\(sign)\(String(format: "%.3f", absValue * 1e12))p" }
        if absValue >= 1e-15 { return "\(sign)\(String(format: "%.3f", absValue * 1e15))f" }
        return "\(sign)\(String(format: "%.3e", absValue))"
    }

    private func resolveManifestURL() -> URL {
        if runPath.lastPathComponent == "manifest.json" {
            return runPath
        }
        return runPath.appending(path: "manifest.json")
    }
}
