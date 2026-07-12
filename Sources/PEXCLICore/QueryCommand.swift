import Foundation
import PEXEngine

/// Queries persisted ParasiticIR without requiring a UI or an in-process
/// caller. The command deliberately exposes the same three typed operations
/// as `PEXService` so agents can inspect a run from a stable CLI contract.
public struct QueryCommand: Sendable {
    public enum Kind: Sendable, Equatable {
        case net(NetName, PEXCornerID)
        case module(InstancePath, PEXCornerID)
        case cornerDelta(PEXCornerID, PEXCornerID)
    }

    public let runPath: URL
    public let kind: Kind
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        var runPath: String?
        var net: String?
        var module: String?
        var corner: String?
        var baseCorner: String?
        var targetCorner: String?
        var json = false
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--run":
                index += 1
                guard index < arguments.count else {
                    throw PEXError.invalidInput("--run requires a path argument")
                }
                runPath = arguments[index]
            case "--net":
                index += 1
                guard index < arguments.count else {
                    throw PEXError.invalidInput("--net requires a name argument")
                }
                net = arguments[index]
            case "--module":
                index += 1
                guard index < arguments.count else {
                    throw PEXError.invalidInput("--module requires an instance path argument")
                }
                module = arguments[index]
            case "--corner":
                index += 1
                guard index < arguments.count else {
                    throw PEXError.invalidInput("--corner requires an ID argument")
                }
                corner = arguments[index]
            case "--base-corner":
                index += 1
                guard index < arguments.count else {
                    throw PEXError.invalidInput("--base-corner requires an ID argument")
                }
                baseCorner = arguments[index]
            case "--target-corner":
                index += 1
                guard index < arguments.count else {
                    throw PEXError.invalidInput("--target-corner requires an ID argument")
                }
                targetCorner = arguments[index]
            case "--json":
                json = true
            default:
                throw PEXError.invalidInput("Unknown query argument '\(arguments[index])'")
            }
            index += 1
        }

        guard let runPath, !runPath.isEmpty else {
            throw PEXError.invalidInput("query requires --run <path>")
        }
        let selectedModes = [net != nil, module != nil, baseCorner != nil || targetCorner != nil]
            .filter { $0 }
            .count
        guard selectedModes == 1 else {
            throw PEXError.invalidInput("query requires exactly one of --net, --module, or --base-corner/--target-corner")
        }

        if let net {
            guard let corner, !corner.isEmpty else {
                throw PEXError.invalidInput("--corner is required with --net")
            }
            guard baseCorner == nil, targetCorner == nil, module == nil else {
                throw PEXError.invalidInput("--net cannot be combined with another query mode")
            }
            self.kind = .net(NetName(net), PEXCornerID(corner))
        } else if let module {
            guard let corner, !corner.isEmpty else {
                throw PEXError.invalidInput("--corner is required with --module")
            }
            guard baseCorner == nil, targetCorner == nil, net == nil else {
                throw PEXError.invalidInput("--module cannot be combined with another query mode")
            }
            self.kind = .module(InstancePath(module), PEXCornerID(corner))
        } else {
            guard let baseCorner, !baseCorner.isEmpty,
                  let targetCorner, !targetCorner.isEmpty else {
                throw PEXError.invalidInput("--base-corner and --target-corner are required for a corner delta query")
            }
            guard corner == nil, net == nil, module == nil else {
                throw PEXError.invalidInput("Corner delta queries cannot use --corner, --net, or --module")
            }
            self.kind = .cornerDelta(PEXCornerID(baseCorner), PEXCornerID(targetCorner))
        }
        self.runPath = URL(filePath: runPath)
        self.jsonOutput = json
    }

    public func run() async throws {
        let manifestURL = runPath.lastPathComponent == "manifest.json"
            ? runPath
            : runPath.appending(path: "manifest.json")
        let resolver = try PEXArtifactResolver(manifestURL: manifestURL)
        let workspace = PEXRunWorkspace(
            baseURL: resolver.runDirectory.deletingLastPathComponent(),
            runID: resolver.manifest.runID
        )
        let service = DefaultPEXService.withDefaults()

        switch kind {
        case let .net(net, corner):
            let result = try service.queryNet(net, runID: resolver.manifest.runID, corner: corner, workspace: workspace.baseURL)
            try emitJSONOrText(kind: "net", result: result) {
                print("Net: \(result.netName.value)")
                print("Corner: \(result.cornerID.value)")
                print("Nodes: \(result.nodeCount), Elements: \(result.elementCount)")
                print("Ground capacitance: \(formatEngineering(result.totalGroundCapF))F")
                print("Coupling capacitance: \(formatEngineering(result.totalCouplingCapF))F")
                print("Resistance: \(formatEngineering(result.totalResistanceOhm))Ohm")
            }
        case let .module(module, corner):
            let result = try service.moduleSummary(module, runID: resolver.manifest.runID, corner: corner, workspace: workspace.baseURL)
            try emitJSONOrText(kind: "module", result: result) {
                print("Module: \(result.modulePath.value)")
                print("Corner: \(result.cornerID.value)")
                print("Nets: \(result.netNames.map(\.value).joined(separator: ", "))")
                print("Nodes: \(result.nodeCount), Elements: \(result.elementCount)")
                print("Ground capacitance: \(formatEngineering(result.totalGroundCapF))F")
                print("Coupling capacitance: \(formatEngineering(result.totalCouplingCapF))F")
                print("Resistance: \(formatEngineering(result.totalResistanceOhm))Ohm")
            }
        case let .cornerDelta(baseCorner, targetCorner):
            let result = try service.cornerDelta(
                runID: resolver.manifest.runID,
                baseCorner: baseCorner,
                targetCorner: targetCorner,
                workspace: workspace.baseURL
            )
            try emitJSONOrText(kind: "cornerDelta", result: result) {
                print("Corners: \(result.baseCornerID.value) -> \(result.targetCornerID.value)")
                print("Net deltas: \(result.netDeltas.count)")
                print("Ground capacitance delta: \(formatEngineering(result.totalGroundCapDeltaF))F")
                print("Coupling capacitance delta: \(formatEngineering(result.totalCouplingCapDeltaF))F")
                print("Resistance delta: \(formatEngineering(result.totalResistanceDeltaOhm))Ohm")
            }
        }
    }

    private func emitJSONOrText<T: Encodable>(kind: String, result: T, text: () -> Void) throws {
        if jsonOutput {
            let payload = QueryJSONEnvelope(kind: kind, result: result)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            text()
        }
    }

    private func formatEngineering(_ value: Double) -> String {
        if value == 0 { return "0" }
        let absolute = abs(value)
        let sign = value < 0 ? "-" : ""
        let (scaled, suffix): (Double, String) = switch absolute {
        case 1e9...: (absolute / 1e9, "G")
        case 1e6...: (absolute / 1e6, "M")
        case 1e3...: (absolute / 1e3, "k")
        case 1...: (absolute, "")
        case 1e-3...: (absolute * 1e3, "m")
        case 1e-6...: (absolute * 1e6, "u")
        case 1e-9...: (absolute * 1e9, "n")
        case 1e-12...: (absolute * 1e12, "p")
        case 1e-15...: (absolute * 1e15, "f")
        default: (absolute, "")
        }
        let format = scaled < 1e-6 ? "%.3e" : "%.3f"
        return "\(sign)\(String(format: format, scaled))\(suffix)"
    }
}

private struct QueryJSONEnvelope<Result: Encodable>: Encodable {
    let query: String
    let result: Result

    init(kind: String, result: Result) {
        self.query = kind
        self.result = result
    }
}
