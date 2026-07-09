import Foundation

public struct PEXTechnologyReference: Sendable, Codable, Hashable {
    public let sourceKind: String
    public let path: String?
    public let processName: String?

    public init(sourceKind: String, path: String? = nil, processName: String? = nil) {
        self.sourceKind = sourceKind
        self.path = path
        self.processName = processName
    }

    public init(input: TechnologyInput) {
        switch input {
        case .jsonFile(let url):
            self.init(
                sourceKind: "jsonFile",
                path: url.path(percentEncoded: false),
                processName: nil
            )
        case .inline(let technology):
            self.init(
                sourceKind: "inline",
                path: nil,
                processName: technology.processName
            )
        }
    }
}
