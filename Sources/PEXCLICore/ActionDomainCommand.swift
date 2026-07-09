import Foundation
import PEXEngine

public struct ActionDomainCommand: Sendable {
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        var jsonOutput = false
        for argument in arguments {
            switch argument {
            case "--json":
                jsonOutput = true
            default:
                throw PEXError.invalidInput("Unknown action-domain argument: \(argument)")
            }
        }
        self.jsonOutput = jsonOutput
    }

    public func run() throws {
        let snapshot = PEXActionDomainExporter().snapshot()
        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("action_domain=\(snapshot.domainID)")
            print("operations=\(snapshot.operations.count)")
        }
    }
}

