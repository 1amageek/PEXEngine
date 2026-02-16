public struct PEXWarning: Sendable, Codable, Hashable {
    public let stage: PEXStage
    public let cornerID: PEXCornerID?
    public let message: String

    public init(
        stage: PEXStage,
        cornerID: PEXCornerID? = nil,
        message: String
    ) {
        self.stage = stage
        self.cornerID = cornerID
        self.message = message
    }
}
