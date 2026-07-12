import Foundation

public struct PEXSPICEWriterOptions: Sendable, Hashable {
    public let subcircuitName: String?
    public let includeNodeMapComments: Bool

    public init(
        subcircuitName: String? = nil,
        includeNodeMapComments: Bool = true
    ) {
        self.subcircuitName = subcircuitName
        self.includeNodeMapComments = includeNodeMapComments
    }
}
