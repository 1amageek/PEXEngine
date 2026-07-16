import PEXCore
import PEXParsers

public enum PEXDefaultParsers {
    public static func makeAll() -> [any PEXParsing] {
        [
            SPEFPEXParser(),
            DSPFPEXParser(),
            MagicSPICEParasiticParser(),
        ]
    }

    public static func makeRegistry() -> PEXParserRegistry {
        let registry = PEXParserRegistry()
        for parser in makeAll() {
            registry.register(parser)
        }
        return registry
    }
}
