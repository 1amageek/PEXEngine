import Synchronization

public final class PEXAdapterRegistry: Sendable {
    private let adapters: Mutex<[String: any PEXExtracting]>

    public init() {
        self.adapters = Mutex([:])
    }

    public init(adapters: [any PEXExtracting]) {
        var dict: [String: any PEXExtracting] = [:]
        for adapter in adapters {
            dict[adapter.backendID] = adapter
        }
        self.adapters = Mutex(dict)
    }

    public func register(_ adapter: any PEXExtracting) {
        adapters.withLock { $0[adapter.backendID] = adapter }
    }

    public func adapter(for backendID: String) -> (any PEXExtracting)? {
        adapters.withLock { $0[backendID] }
    }

    public var registeredBackends: [String] {
        adapters.withLock { Array($0.keys).sorted() }
    }
}
