import Foundation
import PEXEngine

public enum CLIRouter {
    public static func run(arguments: [String]) async {
        guard let command = arguments.first else {
            printUsage()
            return
        }

        do {
            switch command {
            case "extract":
                let cmd = try ExtractCommand(arguments: Array(arguments.dropFirst()))
                try await cmd.run()
            case "parse":
                let cmd = try ParseCommand(arguments: Array(arguments.dropFirst()))
                try await cmd.run()
            case "validate-tech":
                let cmd = try ValidateTechCommand(arguments: Array(arguments.dropFirst()))
                try await cmd.run()
            case "summarize":
                let cmd = try SummarizeCommand(arguments: Array(arguments.dropFirst()))
                try await cmd.run()
            case "doctor":
                let cmd = DoctorCommand(arguments: Array(arguments.dropFirst()))
                try await cmd.run()
            case "list-backends":
                let cmd = try ListBackendsCommand(arguments: Array(arguments.dropFirst()))
                try cmd.run()
            case "--version", "-v":
                print("pexengine 0.1.0")
            case "--help", "-h":
                printUsage()
            default:
                fputs("error: unknown command '\(command)'\n", stderr)
                fputs("Run 'pexengine --help' for usage.\n", stderr)
                _exit(1)
            }
        } catch let error as PEXError {
            fputs("error: \(error.description)\n", stderr)
            _exit(exitCode(for: error.kind))
        } catch {
            fputs("error: \(error)\n", stderr)
            _exit(1)
        }
    }

    public static func printUsage() {
        print("""
        pexengine - Parasitic Extraction Engine

        USAGE:
          pexengine <command> [options]

        COMMANDS:
          extract         Run parasitic extraction
            --config <path>       Path to PEX project config JSON
            --layout <path>       Layout file path (direct mode)
            --netlist <path>      Netlist file path (direct mode)
            --top-cell <name>     Top cell name (direct mode)
            --technology <path>   Technology file path (direct mode)
            --backend <id>        Backend ID (default: mock)
            --corner <id>         Corner ID (repeatable)
            --max-jobs <n>        Max parallel jobs
            --include-coupling    Include coupling capacitances
            --min-cap-f <val>     Minimum capacitance threshold (F)
            --min-res-ohm <val>   Minimum resistance threshold (Ohm)
            --out <path>          Output workspace path
            --strict              Enable strict validation
            --json                Output results as JSON

          parse           Parse a SPEF/DSPF file
            --input <path>    Path to SPEF/DSPF file
            --format <fmt>    Format: spef, dspf (default: spef)
            --corner <id>     Corner ID (default: default)
            --json            Output results as JSON

          validate-tech   Validate a technology file
            --technology <path>   Path to technology JSON file
            --strict              Strict validation
            --json                Output as JSON

          summarize       Summarize extraction run results
            --run <path>          Path to run directory
            --top-nets <n>        Show top N nets (default: 10)
            --corner <id>         Filter by corner
            --json                Output as JSON

          doctor          Diagnose environment and configuration
            --json                Output as JSON

          list-backends   List registered backend adapters
            --json                Output as JSON

        OPTIONS:
          --version, -v   Show version
          --help, -h      Show this help
        """)
    }

    public static func exitCode(for kind: PEXErrorKind) -> Int32 {
        switch kind {
        case .invalidInput: return 1
        case .technologyResolutionFailed: return 2
        case .adapterUnavailable: return 1
        case .backendExecutionFailed: return 3
        case .parseFailed: return 4
        case .irValidationFailed: return 4
        case .persistenceFailed: return 5
        case .internalInvariantViolation: return 5
        }
    }
}
