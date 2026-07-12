import Foundation
import PEXEngine

/// Reports the effective parent-to-leaf retry lineage of a persisted run.
public struct LineageCommand: Sendable {
    public let manifestURL: URL
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        var runPath: String?
        var jsonOutput = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--run":
                index += 1
                guard index < arguments.count else {
                    throw PEXError.invalidInput("--run requires a manifest path")
                }
                runPath = arguments[index]
            case "--json":
                jsonOutput = true
            default:
                throw PEXError.invalidInput("Unknown lineage argument: \(argument)")
            }
            index += 1
        }

        guard let runPath, !runPath.isEmpty else {
            throw PEXError.invalidInput("lineage requires --run <manifest-path>")
        }
        self.manifestURL = URL(filePath: runPath)
        self.jsonOutput = jsonOutput
    }

    public func run() async throws {
        let resolver = try PEXArtifactResolver(manifestURL: manifestURL)
        let workspace = PEXRunWorkspace(
            baseURL: resolver.runDirectory.deletingLastPathComponent(),
            runID: resolver.manifest.runID
        )
        let lineage = try PEXArtifactStore(workspace: workspace).loadLineage()
        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(lineage)
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        print("Root run: \(lineage.rootRunID)")
        print("Leaf run: \(lineage.leafRunID)")
        print("Effective status: \(lineage.effectiveStatus.rawValue)")
        print("Runs: \(lineage.runs.count)")
        for run in lineage.runs {
            print("  \(run.runID): \(run.status.rawValue) corners=\(run.cornerIDs.map(\.value).joined(separator: ","))")
        }
        print("Effective corners:")
        for corner in lineage.effectiveCorners {
            print("  \(corner.cornerID.value): \(corner.status.rawValue) source=\(corner.sourceRunID)")
        }
    }
}
