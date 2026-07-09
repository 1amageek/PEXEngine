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
            case "write-spef":
                let cmd = try WriteSPEFCommand(arguments: Array(arguments.dropFirst()))
                try await cmd.run()
            case "compare-ir":
                let cmd = try CompareIRCommand(arguments: Array(arguments.dropFirst()))
                let passed = try await cmd.run()
                if !passed {
                    _exit(exitCode(for: .irValidationFailed))
                }
            case "parse-corpus":
                let cmd = try ParseCorpusCommand(arguments: Array(arguments.dropFirst()))
                let qualified = try await cmd.run()
                if !qualified {
                    _exit(exitCode(for: .irValidationFailed))
                }
            case "evidence-from-corpus-report":
                let cmd = try EvidenceFromCorpusReportCommand(arguments: Array(arguments.dropFirst()))
                let qualified = try await cmd.run()
                if !qualified {
                    _exit(exitCode(for: .irValidationFailed))
                }
            case "evidence-packet-from-corpus-report":
                let cmd = try EvidencePacketFromCorpusReportCommand(arguments: Array(arguments.dropFirst()))
                try await cmd.run()
            case "evidence-packet-from-extractor-report":
                let cmd = try EvidencePacketFromExtractorReportCommand(arguments: Array(arguments.dropFirst()))
                try await cmd.run()
            case "audit-extractor-physical-bounds":
                let cmd = try AuditExtractorPhysicalBoundsCommand(arguments: Array(arguments.dropFirst()))
                let satisfied = try await cmd.run()
                if !satisfied {
                    _exit(exitCode(for: .irValidationFailed))
                }
            case "metric-recovery-objective":
                let cmd = try MetricRecoveryObjectiveCommand(arguments: Array(arguments.dropFirst()))
                try await cmd.run()
            case "validate-tech":
                let cmd = try ValidateTechCommand(arguments: Array(arguments.dropFirst()))
                try await cmd.run()
            case "summarize":
                let cmd = try SummarizeCommand(arguments: Array(arguments.dropFirst()))
                try await cmd.run()
            case "doctor":
                let cmd = try DoctorCommand(arguments: Array(arguments.dropFirst()))
                try await cmd.run()
            case "list-backends":
                let cmd = try ListBackendsCommand(arguments: Array(arguments.dropFirst()))
                try cmd.run()
            case "action-domain":
                let cmd = try ActionDomainCommand(arguments: Array(arguments.dropFirst()))
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
            --backend <id>        Backend ID (required in direct mode)
            --corner <id>         Corner ID (repeatable)
            --max-jobs <n>        Max parallel jobs
            --include-coupling    Include coupling capacitances
            --min-cap-f <val>     Minimum capacitance threshold (F)
            --min-res-ohm <val>   Minimum resistance threshold (Ohm)
            --out <path>          Output workspace path
            --strict              Enable strict validation (default)
            --non-strict          Report IR validation errors as warnings
            --summary             Include post-extraction net summary
            --summary-top-nets <n> Summary top nets per corner (default: 10)
            --json                Output results as JSON

          parse           Parse a SPEF file
            --input <path>    Path to SPEF file
            --format <fmt>    Format: spef (default: spef)
            --corner <id>     Corner ID (default: default)
            --report          Emit status, summary, and validation diagnostics instead of raw IR
            --json            Output results as JSON

          write-spef      Write a SPEF file from retained ParasiticIR JSON
            --input <path>       Path to ParasiticIR JSON
            --output <path>      Output SPEF file path
            --report <path>      Write SPEF write report JSON
            --round-trip         Parse generated SPEF back into ParasiticIR and validate it
            --round-trip-corner <id>
                                  Override round-trip validation corner ID
            --design-name <name> Override SPEF design name
            --date <date>        Override SPEF date
            --vendor <name>      Override SPEF vendor
            --program <name>     Override SPEF program
            --json               Output write report as JSON

          compare-ir      Compare baseline and candidate ParasiticIR JSON files
            --baseline <path>    Baseline ParasiticIR JSON
            --candidate <path>   Candidate ParasiticIR JSON
            --report <path>      Write comparison report JSON
            --cap-abs-tolerance-f <value>
                                Maximum allowed capacitance increase per net
            --cap-rel-tolerance <value>
                                Maximum allowed relative capacitance increase per net
            --res-abs-tolerance-ohm <value>
                                Maximum allowed resistance increase per net
            --res-rel-tolerance <value>
                                Maximum allowed relative resistance increase per net
            --equivalence       Require semantic equivalence instead of regression-only comparison
            --value-abs-tolerance <value>
                                Absolute tolerance for semantic value comparison
            --allow-net-set-changes
                                Do not fail when candidate adds or removes nets
            --json               Output comparison report as JSON

          parse-corpus    Validate a SPEF fixture corpus
            --manifest <path>      Corpus manifest JSON
            --fixtures-dir <path>  Fixture directory (default: manifest directory)
            --out <path>           Write report JSON
            --json                 Output report as JSON

          evidence-from-corpus-report
                          Export ToolEvidence-compatible JSON from a SPEF corpus report
            --report <path>        SPEF corpus report JSON
            --evidence-id <id>     Override evidence ID
            --checked-at <time>    ISO 8601 timestamp
            --json                 Output export as JSON

          evidence-packet-from-corpus-report
                          Export Agent-readable PEX evidence packet from a SPEF corpus report
            --report <path>        SPEF corpus report JSON
            --out <path>           Write packet JSON
            --packet-id <id>       Override packet ID
            --json                 Output packet as JSON

          evidence-packet-from-extractor-report
                          Export Agent-readable PEX evidence packet from a real extractor report
            --report <path>        PEX real extractor report JSON
            --out <path>           Write packet JSON
            --packet-id <id>       Override packet ID
            --json                 Output packet as JSON

          audit-extractor-physical-bounds
                          Audit retained real-extractor physical capacitance/resistance bounds
            --report <path>        PEX real extractor report JSON
            --out <path>           Write audit JSON
            --audit-id <id>        Override audit ID
            --json                 Output audit as JSON

          metric-recovery-objective
                          Create Agent-readable PEX recovery planning material
            --summary <path>        PEX summary JSON
            --comparison <path>     Optional PEX IR comparison report JSON
            --metric-report <path>  Optional post-layout metric report JSON
            --layout <path>         Optional layout reference
            --source-netlist <path> Optional source netlist reference
            --technology <path>     Optional technology reference
            --out <path>            Write planning problem JSON
            --problem-id <id>       Override problem ID
            --json                  Output planning problem as JSON

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

          action-domain   Emit planner-visible PEX action domain
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
        case .cancelled: return 130
        case .parseFailed: return 4
        case .irValidationFailed: return 4
        case .persistenceFailed: return 5
        case .internalInvariantViolation: return 5
        }
    }
}
