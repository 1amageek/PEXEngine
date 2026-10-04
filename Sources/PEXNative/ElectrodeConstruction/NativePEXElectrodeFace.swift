/// An oriented, exposed sheet boundary in the snapshot's coordinate units.
public struct NativePEXElectrodeFace: Sendable, Hashable, Codable {
    public enum Side: String, Sendable, Hashable, Codable {
        case minX, maxX, minY, maxY
        var alongX: Bool { self == .minY || self == .maxY }
        var opposite: Self {
            switch self { case .minX: .maxX; case .maxX: .minX; case .minY: .maxY; case .maxY: .minY }
        }
    }
    public let side: Side
    public let coordinate: Int32
    public let begin: Int32
    public let end: Int32

    public init(side: Side, coordinate: Int32, begin: Int32, end: Int32) {
        self.side = side; self.coordinate = coordinate; self.begin = begin; self.end = end
    }
}
