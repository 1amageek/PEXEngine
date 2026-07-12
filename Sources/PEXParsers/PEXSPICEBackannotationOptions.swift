import Foundation

public struct PEXSPICEBackannotationOptions: Sendable, Hashable {
    public let topCell: String?
    public let subcircuitName: String?
    public let instanceName: String?
    public let requirePortMatches: Bool

    public init(
        topCell: String? = nil,
        subcircuitName: String? = nil,
        instanceName: String? = nil,
        requirePortMatches: Bool = true
    ) {
        self.topCell = topCell?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subcircuitName = subcircuitName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.instanceName = instanceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requirePortMatches = requirePortMatches
    }
}
