import Foundation

/// A durable net selector interpreted only against the actual captured source.
public enum NativePEXInputNetSelector: Sendable, Equatable, Hashable, Codable {
    case sourceDeclared(occurrenceIndex: Int, expectedCellName: String, sourceNetName: String)
    case supplemental(occurrenceIndex: Int, expectedCellName: String, netID: UUID)

    public var occurrenceIndex: Int {
        switch self {
        case .sourceDeclared(let index, _, _), .supplemental(let index, _, _): index
        }
    }

    public var expectedCellName: String {
        switch self {
        case .sourceDeclared(_, let name, _), .supplemental(_, let name, _): name
        }
    }
}
