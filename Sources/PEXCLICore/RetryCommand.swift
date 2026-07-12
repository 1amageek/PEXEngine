import Foundation
import PEXEngine

/// Retries only failed corners from a persisted run using its captured inputs.
public struct RetryCommand: Sendable {
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
                throw PEXError.invalidInput("Unknown retry argument: \(argument)")
            }
            index += 1
        }

        guard let runPath, !runPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PEXError.invalidInput("retry requires --run <manifest-path>")
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
        let store = PEXArtifactStore(workspace: workspace)
        let previousResult = try store.loadResult(manifest: resolver.manifest)
        let request = try store.loadRequest()
        let result = try await DefaultPEXEngine.withDefaults().retryFailedCorners(
            request,
            from: previousResult
        )

        let outputCommand = try ExtractCommand(arguments: jsonOutput ? ["--json"] : [])
        try await outputCommand.emit(result)
        try outputCommand.validate(result)
    }
}
