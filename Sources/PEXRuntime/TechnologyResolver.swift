import Foundation
import PEXCore

public struct TechnologyResolver: Sendable {
    public init() {}

    public func resolve(_ input: TechnologyInput) throws -> TechnologyIR {
        switch input {
        case .jsonFile(let url):
            return try resolveJSON(url)
        case .tomlFile:
            throw PEXError.technologyResolutionFailed("TOML technology files are not yet supported")
        case .directory:
            throw PEXError.technologyResolutionFailed("Directory-based technology packages are not yet supported")
        case .inline(let ir):
            return ir
        }
    }

    private func resolveJSON(_ url: URL) throws -> TechnologyIR {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PEXError.technologyResolutionFailed(
                "Failed to read technology file: \(url.path(percentEncoded: false))",
                underlying: error
            )
        }
        do {
            return try JSONDecoder().decode(TechnologyIR.self, from: data)
        } catch {
            throw PEXError.technologyResolutionFailed(
                "Failed to decode technology JSON: \(url.lastPathComponent)",
                underlying: error
            )
        }
    }
}
