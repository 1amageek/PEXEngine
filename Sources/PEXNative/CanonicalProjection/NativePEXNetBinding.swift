import Foundation
import LayoutVerify
import PEXCore

/// An exact resolved occurrence-scoped net, explicitly bound to a source net identity.
public struct NativePEXNetBinding: Sendable, Equatable, Codable {
    public let occurrenceIndex: Int
    public let netID: UUID
    public let netName: NetName

    public init(occurrenceIndex: Int, netID: UUID, netName: NetName) {
        self.occurrenceIndex = occurrenceIndex; self.netID = netID; self.netName = netName
    }
    public init(reference: LayoutConductorSnapshot.NetReference, netName: NetName) {
        self.init(occurrenceIndex: reference.occurrenceIndex, netID: reference.netID, netName: netName)
    }
}
