import Foundation
import PEXCore

public struct TechnologyResolver: Sendable {
    public init() {}

    public func resolve(_ input: TechnologyInput) throws -> TechnologyIR {
        let technology: TechnologyIR
        switch input {
        case .jsonFile(let url):
            technology = try resolveJSON(url)
        case .inline(let ir):
            technology = ir
        }
        try technology.validateElectricalModels()
        return technology
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
