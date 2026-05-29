import PEXCore

/// The canonical set of PEX backends registered by default, shared by the engine
/// and the CLI's list/doctor commands so they never drift. The mock stays first
/// (mandatory for tests/preview); the real Magic backend is selectable by id and
/// fails loud at execute time if its toolchain is absent.
public enum PEXDefaultBackends {
    public static func makeAll() -> [any PEXAdapter] {
        [MockPEXAdapter(), MagicPEXAdapter()]
    }
}
