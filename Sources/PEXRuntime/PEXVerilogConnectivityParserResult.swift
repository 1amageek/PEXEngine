import Foundation

public struct PEXVerilogConnectivityParserResult: Sendable, Codable, Hashable {
    public let sourceNodes: [String]
    public let moduleNames: [String]
    public let parsedPortCount: Int
    public let parsedInstanceCount: Int
    public let diagnostics: [String]

    public init(
        sourceNodes: [String],
        moduleNames: [String],
        parsedPortCount: Int,
        parsedInstanceCount: Int,
        diagnostics: [String] = []
    ) {
        self.sourceNodes = Array(Set(sourceNodes.map(Self.normalize).filter { !$0.isEmpty })).sorted()
        self.moduleNames = Array(Set(moduleNames.map(Self.normalize).filter { !$0.isEmpty })).sorted()
        self.parsedPortCount = parsedPortCount
        self.parsedInstanceCount = parsedInstanceCount
        self.diagnostics = Array(Set(diagnostics)).sorted()
    }

    public var isUsable: Bool {
        !moduleNames.isEmpty && diagnostics.isEmpty
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
