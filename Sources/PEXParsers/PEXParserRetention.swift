import Synchronization

/// Keep this anchor alive while any shared copy of its controlled value is alive.
public struct PEXParserRetention: Sendable {
    fileprivate let owner: Owner

    fileprivate final class Owner: Sendable {
        let storage = Mutex<[any Sendable]>([])
        let metadata: any Sendable

        init(metadata: any Sendable) { self.metadata = metadata }
    }

    fileprivate init(owner: Owner) { self.owner = owner }
}

/// One operation's original cumulative control and construction-only lease storage.
/// Output copies share the retained owner; temporary owners end with this scope.
final class PEXParserResourceScope: Sendable {
    let control: any PEXParserResourceControlling
    let retention: PEXParserRetention
    private let temporary: Mutex<[any Sendable]>

    init(control: any PEXParserResourceControlling, retained: UInt64 = 0,
         temporary: UInt64 = 0) throws {
        try control.checkpoint(workUnits: 0)
        // Logical stored fields/state, excluding allocator and mutex runtime headers.
        let metadataBytes = UInt64(MemoryLayout<any PEXParserResourceControlling>.stride
            + MemoryLayout<PEXParserRetention>.stride
            + 2 * MemoryLayout<Mutex<[any Sendable]>>.stride
            + 2 * MemoryLayout<[any Sendable]>.stride
            + MemoryLayout<any Sendable>.stride)
        let metadata = try control.reserveStorage(kind: .retained, byteCount: metadataBytes)
        try control.checkpoint(workUnits: 0)
        self.control = control
        self.temporary = Mutex([])
        self.retention = PEXParserRetention(owner: .init(metadata: metadata))
        if retained > 0 { try reserve(kind: .retained, byteCount: retained) }
        if temporary > 0 { try reserve(kind: .temporary, byteCount: temporary) }
    }

    /// Admit explicit logical payload before construction, including its lease slot.
    func reserve(kind: PEXParserStorageKind, byteCount: UInt64) throws {
        try check(0)
        // N admitted reservations cover N new and N old lease slots during growth.
        let slots = UInt64(2 * MemoryLayout<any Sendable>.stride)
        let (total, overflow) = byteCount.addingReportingOverflow(slots)
        guard !overflow else { throw PEXParserResourceError.capacityOverflow }
        let lease = try control.reserveStorage(kind: kind, byteCount: total)
        try check(0)
        switch kind {
        case .temporary: temporary.withLock { $0.append(lease) }
        case .retained: retention.owner.storage.withLock { $0.append(lease) }
        }
    }

    func withTemporaryStorage<Result>(byteCount: UInt64,
        _ body: () throws -> Result) throws -> Result {
        try check(0)
        let (total, overflow) = byteCount.addingReportingOverflow(UInt64(MemoryLayout<any Sendable>.stride))
        guard !overflow else { throw PEXParserResourceError.capacityOverflow }
        let lease = try control.reserveStorage(kind: .temporary, byteCount: total)
        try check(0)
        defer { withExtendedLifetime(lease) {} }
        return try body()
    }

    /// Invoke only at a known source-error construction boundary, never in a
    /// catch-all around fallible control callbacks. The builder formats lazily.
    func sourceFailure<Failure: Error>(diagnosticBytes: Int,
        _ make: () -> Failure) throws -> PEXParserSourceFailure {
        let fields = try PEXParserStorageSize.add(MemoryLayout<Failure>.stride,
            MemoryLayout<PEXParserSourceFailure>.stride)
        let bytes = try PEXParserStorageSize.add(fields, diagnosticBytes)
        try reserve(kind: .retained, byteCount: UInt64(bytes))
        try check(0)
        return PEXParserSourceFailure(cause: make(), retention: retention)
    }

    func check(_ units: UInt64 = 1) throws {
        try control.checkpoint(workUnits: 0)
        try control.checkpoint(workUnits: units)
        try control.checkpoint(workUnits: 0)
    }
}

/// Checked logical payload arithmetic, independent of allocator bucket overhead.
enum PEXParserStorageSize {
    static func add(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard a >= 0, b >= 0, !overflow else { throw PEXParserResourceError.capacityOverflow }
        return value
    }

    static func multiply(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard a >= 0, b >= 0, !overflow else { throw PEXParserResourceError.capacityOverflow }
        return value
    }

    static func array<T>(_ type: T.Type, count: Int) throws -> Int {
        try add(MemoryLayout<[T]>.stride, multiply(count, MemoryLayout<T>.stride))
    }

    static func dictionary<Key: Hashable, Value>(_ key: Key.Type, _ value: Value.Type, count: Int) throws -> Int {
        try add(MemoryLayout<[Key: Value]>.stride, multiply(count, MemoryLayout<(Key, Value)>.stride))
    }
}
