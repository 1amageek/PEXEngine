/// Storage charged by a controlled standard-format operation.
public enum PEXParserStorageKind: Sendable {
    case temporary
    case retained
}

/// A caller-owned cumulative resource ledger. Returned owners release reservations.
public protocol PEXParserResourceControlling: Sendable {
    func checkpoint(workUnits: UInt64) throws
    func reserveStorage(kind: PEXParserStorageKind, byteCount: UInt64) throws -> any Sendable
}

public enum PEXParserResourceError: Error, Sendable {
    case capacityOverflow
}
