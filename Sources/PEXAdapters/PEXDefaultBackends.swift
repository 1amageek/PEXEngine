import PEXCore

/// Production PEX backends shared by engine and CLI discovery.
public enum PEXDefaultBackends {
    public static func makeAll() -> [any PEXAdapter] {
        [MagicPEXAdapter()]
    }
}
