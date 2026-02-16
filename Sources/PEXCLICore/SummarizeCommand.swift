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
                break
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
        let manifestURL = runPath.appending(path: "manifest.json")
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw PEXError.persistenceFailed("Failed to read manifest at \(manifestURL.path(percentEncoded: false))", underlying: error)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: PEXManifest
        do {
            manifest = try decoder.decode(PEXManifest.self, from: data)
        } catch {
            throw PEXError.persistenceFailed("Failed to decode manifest", underlying: error)
        }

        let serializer = PEXIRSerializer()
        let irDirectory = runPath.appending(path: "ir")
        var cornerSummaries: [CornerSummary] = []

        let cornersToProcess: [PEXManifest.CornerEntry]
        if let filter = cornerFilter {
            cornersToProcess = manifest.corners.filter { $0.cornerID == filter }
            if cornersToProcess.isEmpty {
                throw PEXError.invalidInput("Corner '\(filter.value)' not found in run")
            }
        } else {
            cornersToProcess = manifest.corners
        }

        for entry in cornersToProcess {
            let irURL = irDirectory.appending(path: "\(entry.cornerID.value).json")
            let irData: Data
            do {
                irData = try Data(contentsOf: irURL)
            } catch {
                cornerSummaries.append(CornerSummary(cornerID: entry.cornerID.value, status: entry.status.rawValue, netCount: 0, elementCount: 0, topNets: []))
                continue
            }
            do {
                let ir = try serializer.decode(from: irData)
                let sortedNets = ir.nets
                    .sorted { ($0.totalGroundCapF + $0.totalCouplingCapF) > ($1.totalGroundCapF + $1.totalCouplingCapF) }
                    .prefix(topNets)
                let topNetEntries = sortedNets.map {
                    NetEntry(name: $0.name.value, groundCapF: $0.totalGroundCapF, couplingCapF: $0.totalCouplingCapF, resistanceOhm: $0.totalResistanceOhm, nodeCount: $0.nodes.count)
                }
                cornerSummaries.append(CornerSummary(
                    cornerID: entry.cornerID.value,
                    status: entry.status.rawValue,
                    netCount: ir.nets.count,
                    elementCount: ir.elements.count,
                    topNets: topNetEntries
                ))
            } catch {
                cornerSummaries.append(CornerSummary(cornerID: entry.cornerID.value, status: "error", netCount: 0, elementCount: 0, topNets: []))
            }
        }

        if jsonOutput {
            let summary = RunSummary(
                runID: manifest.runID.description,
                status: manifest.status.rawValue,
                backendID: manifest.backendID,
                corners: cornerSummaries
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(summary)
            print(String(data: jsonData, encoding: .utf8) ?? "{}")
        } else {
            print("Run: \(manifest.runID)")
            print("Status: \(manifest.status.rawValue)")
            print("Backend: \(manifest.backendID)")
            print("Corners: \(manifest.corners.count)")
            print("")

            for cs in cornerSummaries {
                print("Corner: \(cs.cornerID) (\(cs.status))")
                print("  Nets: \(cs.netCount), Elements: \(cs.elementCount)")
                if !cs.topNets.isEmpty {
                    print("  Top \(cs.topNets.count) nets by capacitance:")
                    for net in cs.topNets {
                        print("    \(net.name): gnd=\(formatEngineering(net.groundCapF))F cc=\(formatEngineering(net.couplingCapF))F R=\(formatEngineering(net.resistanceOhm))Ohm")
                    }
                }
                print("")
            }
        }
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
}

struct RunSummary: Codable {
    let runID: String
    let status: String
    let backendID: String
    let corners: [CornerSummary]
}

struct CornerSummary: Codable {
    let cornerID: String
    let status: String
    let netCount: Int
    let elementCount: Int
    let topNets: [NetEntry]
}

struct NetEntry: Codable {
    let name: String
    let groundCapF: Double
    let couplingCapF: Double
    let resistanceOhm: Double
    let nodeCount: Int
}
