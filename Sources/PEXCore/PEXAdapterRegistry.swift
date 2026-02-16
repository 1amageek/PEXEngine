import Synchronization

public final class PEXAdapterRegistry: Sendable {
    private let adapters: Mutex<[String: any PEXAdapter]>

    public init() {
        self.adapters = Mutex([:])
    }

    public init(adapters: [any PEXAdapter]) {
        var dict: [String: any PEXAdapter] = [:]
        for adapter in adapters {
            dict[adapter.backendID] = adapter
        }
        self.adapters = Mutex(dict)
    }

    public func register(_ adapter: any PEXAdapter) {
        adapters.withLock { $0[adapter.backendID] = adapter }
    }

    public func adapter(for backendID: String) -> (any PEXAdapter)? {
        adapters.withLock { $0[backendID] }
    }

    public var registeredBackends: [String] {
        adapters.withLock { Array($0.keys).sorted() }
    }
}
