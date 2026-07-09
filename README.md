# PEXEngine

A Swift package for parasitic extraction (PEX) of semiconductor layouts. PEXEngine orchestrates extraction backends, parses their outputs, and normalizes results into a tool-agnostic canonical IR.

## Features

- **Backend-agnostic pipeline** -- Abstracts extraction tools behind a unified adapter protocol
- **Canonical Parasitic IR** -- Tool-independent representation of resistors, capacitors, coupling capacitors, and inductors
- **SPEF, DSPF, and Magic SPICE parsers** -- Standard parasitic output lowering with unit normalization, SPEF `*INDUC` and DSPF / extracted-SPICE `L*` inductor support, and consistent `PEXRunOptions` filtering
- **Multi-corner extraction** -- Parallel corner processing with configurable job limits and `extractorRun.multiCorner` worst/spread summaries
- **Immutable artifact persistence** -- Manifest, raw outputs, normalized IR, and summary reports
- **CLI tool** -- `pexengine` commands for extraction, parsing, validation, diagnostics, and optional extraction summaries
- **Parser corpus qualification** -- OpenROAD OpenRCX SPEF fixtures emit structured qualification evidence
- **ToolEvidence export** -- Saved parser-corpus reports can be converted into flow-compatible evidence JSON
- **Configuration via `swift-configuration`** -- JSON config with provider hierarchy (file > defaults)
- **Real-data validation** -- OpenROAD OpenRCX SPEF fixtures and Sky130 back-annotation gates

## Requirements

- Swift 6.3+
- macOS 26+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/PEXEngine.git", from: "0.1.0"),
]
```

Then add the dependency to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: ["PEXEngine"]
),
```

## Architecture

```
PEXRunRequest
    |
    v
[ TechnologyResolver ] --> TechnologyIR
    |
    v
[ PEXAdapter ]         --> PEXRawOutput (SPEF/DSPF/SPICE)
    |
    v
[ PEXParser ]          --> ParasiticIR (canonical)
    |
    v
[ IRValidator ]        --> Validation warnings/errors
    |
    v
[ ArtifactStore ]      --> manifest.json + IR JSON + reports
    |
    v
PEXRunResult
```

### Modules

| Module | Responsibility |
|---|---|
| **PEXCore** | Domain models, IR types, protocols, typed errors, registries, validation |
| **PEXAdapters** | Backend adapters (MockPEXAdapter, ProcessRunner) |
| **PEXParsers** | SPEF lexer / parser / lowering pipeline including `*INDUC`, DSPF lowering including `L*` elements, and Magic SPICE parasitic lowering including `L*` elements |
| **PEXPersistence** | Manifest, workspace layout, IR serializer, artifact store, report generator, run summary builder |
| **PEXRuntime** | Orchestrator (actor), pipeline, technology resolver, config mapper, engine |
| **PEXEngine** | Umbrella module (re-exports all above) |
| **PEXCLICore** | CLI command logic: router, commands, output formatter |
| **PEXCLI** | Thin executable entry point |

### Concurrency Model

- `PEXOrchestrator` is an **actor** for I/O operations and ordered state transitions
- `PEXAdapterRegistry` / `PEXParserRegistry` use **`Mutex<T>`** for synchronous access
- Multi-corner extraction uses **`TaskGroup`** with bounded parallelism
- All data models are **`Sendable`** structs

## Usage

### Library API

```swift
import PEXEngine

// Run extraction
let engine = DefaultPEXEngine.withDefaults()
let request = PEXRunRequest(
    layoutURL: layoutURL,
    layoutFormat: .gds,
    sourceNetlistURL: netlistURL,
    sourceNetlistFormat: .spice,
    topCell: "top",
    corners: [PEXCorner(id: "tt_25c_1v0")],
    technology: .jsonFile(techURL),
    backendSelection: PEXBackendSelection(backendID: "mock"),
    options: .default
)
let result = try await engine.run(request)
let multiCorner = result.extractorRun?.multiCorner

// Query parasitic data
let service = DefaultPEXService.withDefaults()
let summary = try service.queryNet(
    NetName("VDD"),
    runID: result.runID,
    corner: PEXCornerID("tt_25c_1v0"),
    workspace: workspaceURL
)

// Build an Agent-readable per-corner run summary from persisted artifacts
let runSummary = try PEXRunSummaryBuilder().build(
    manifestURL: result.manifestURL,
    topNets: 5
)
```

### CLI

```bash
# Run extraction from config
pexengine extract --config project.json --json

# Run extraction with direct parameters
pexengine extract \
    --layout design.gds \
    --netlist design.sp \
    --top-cell top \
    --technology tech.json \
    --backend mock \
    --corner tt --corner ss \
    --json

# Run extraction and include a persisted per-corner top-net summary in the same JSON response.
# The base JSON response always includes extractorRun.multiCorner when extractorRun is available.
pexengine extract \
    --layout design.gds \
    --netlist design.sp \
    --top-cell top \
    --technology tech.json \
    --backend mock \
    --corner tt --corner ss \
    --summary \
    --summary-top-nets 5 \
    --json

# Parse a SPEF or DSPF file
pexengine parse --input output.spef --corner tt --json
pexengine parse --input output.dspf --format dspf --corner tt --json

# Parse and emit an Agent/developer decision report with validation diagnostics
pexengine parse --input output.spef --corner tt --report --json

# Validate the committed OpenROAD OpenRCX SPEF parser corpus
pexengine parse-corpus \
    --manifest Tests/PEXParsersTests/Fixtures/OpenROAD/fixture-manifest.json \
    --out /tmp/pex-spef-corpus-report.json \
    --json

# Convert a saved parser-corpus report into ToolEvidence-compatible JSON
pexengine evidence-from-corpus-report \
    --report /tmp/pex-spef-corpus-report.json \
    --json

# Convert a saved parser-corpus report into an Agent-readable evidence packet
pexengine evidence-packet-from-corpus-report \
    --report /tmp/pex-spef-corpus-report.json \
    --out /tmp/pex-evidence-packet.json \
    --json

# Convert a retained real-extractor report into the same evidence packet shape
pexengine evidence-packet-from-extractor-report \
    --report /tmp/pex-real-extractor-report.json \
    --out /tmp/pex-extractor-evidence-packet.json \
    --json

# Validate technology file
pexengine validate-tech --technology tech.json --strict

# Summarize extraction results
pexengine summarize --run /path/to/run --top-nets 5

# List available backends
pexengine list-backends --json

# Environment diagnostics
pexengine doctor
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Invalid input / usage error |
| 2 | Technology resolution failure |
| 3 | Backend execution failure |
| 4 | Parse / IR validation failure |
| 5 | Persistence / internal failure |

## Canonical IR

The `ParasiticIR` provides a tool-independent representation:

```
ParasiticIR
  +-- nets: [ParasiticNet]
  |     +-- name: NetName
  |     +-- nodes: [ParasiticNode]
  |     +-- totalGroundCapF, totalCouplingCapF, totalResistanceOhm
  +-- elements: [ParasiticElement]
        +-- kind: resistor | capacitor | coupling
        +-- nodeA, nodeB, value
```

All values are normalized to canonical units: Ohm, Farad, micrometer.

## Build & Test

```bash
# Build
swift build

# Run all tests
swift test

# Run specific module tests
swift test --filter PEXCoreTests
swift test --filter PEXParsersTests
swift test --filter PEXCLITests

# CLI verification
swift run pexengine --version
swift run pexengine doctor
```

## Developer CLI Check

For local development, verify the executable boundary before relying on higher-level
flow integration:

```bash
../scripts/check-developer-cli.sh
```

This builds `pexengine`, runs `extract` through the real executable with the mock
backend, verifies that stdout is parseable JSON, checks that the run manifest and
summary artifacts exist, and confirms that unknown CLI arguments fail instead of
being ignored.

When debugging manually, prefer the executable path that SwiftPM built:

```bash
PEX_BIN="$(swift build --show-bin-path)/pexengine"
"$PEX_BIN" extract \
  --layout design.gds \
  --netlist design.sp \
  --top-cell TOP \
  --technology tech.json \
  --backend mock \
  --out /tmp/pex-run \
  --summary \
  --json
```

For failures, check stderr first. Invalid input exits with code `1`; parse or IR
validation failures exit with code `4`. Successful JSON output includes
`manifestURL`, `completeness.status`, `extractorRun`, `extractorRun.multiCorner`,
and optional `summary`.

## Real Data Validation

PEXEngine keeps real extraction outputs in the test resources so parser and IR
lowering regressions are caught without network access.

| Corpus | Source | Gate |
|---|---|---|
| OpenROAD OpenRCX SPEF | `Tests/PEXParsersTests/Fixtures/OpenROAD/fixture-manifest.json` | `SPEFParserTests/openROADRCXFixturesParseAndLowerToExpectedSummaries` |
| OpenROAD OpenRCX SPEF qualification | `Tests/PEXParsersTests/Fixtures/OpenROAD/fixture-manifest.json` | `pexengine parse-corpus --manifest ... --out ...` |
| OpenROAD OpenRCX SPEF evidence export | Saved parser-corpus report | `pexengine evidence-from-corpus-report --report ... --json` |
| OpenROAD OpenRCX PEX evidence packet | Saved parser-corpus report | `pexengine evidence-packet-from-corpus-report --report ... --json` |
| Sky130 Magic extraction | `Tests/PEXRuntimeTests/Fixtures/pex_plate.gds` | `validation/pex-backannotation.sh` and gated Magic adapter tests |
| Sky130 Magic real-extractor qualification lane | `Tests/PEXRuntimeTests/Fixtures/ExternalExtractor/pex-magic-corpus.json` | `scripts/run-signoff-qualification.py --external-pex-corpus ...` from the LSI workspace root |
| Sky130 Magic real-extractor evidence packet | Saved `pex-real-extractor-report.json` | `pexengine evidence-packet-from-extractor-report --report ... --json` |

Each OpenROAD fixture records source path, pinned commit, Git blob SHA, SHA-256,
byte count, parse counts including inductor sections, and lowered `ParasiticIR`
totals. The fixture corpus
includes small name-map cases, coupling-heavy pattern cases, and several
hundred-net GCD extractions. It carries the required `pex.extract.openrcx` and
`pex.physical-value` coverage tags, so OpenRCX real-output SPEF remains retained
physical-value evidence instead of a parser-only smoke fixture. The
`parse-corpus` command turns that same corpus into an Agent-readable
qualification report with case pass counts, coverage tag counts, required
coverage checks, observed ParasiticIR totals, failure occurrence and kind counts,
structured per-case failures, and `toolEvidence` qualification metrics. Failed
cases preserve diagnostic categories such as `parse_failure` and
`physical_bound_mismatch` with observed/expected values and suggested actions,
so an Agent can distinguish syntax problems from physical-value bound drift.
The `evidence-from-corpus-report` command turns that immutable report into
ToolEvidence-compatible JSON with a checked timestamp, report SHA-256,
qualification metrics, observed counts, and failure codes so flow runtimes and
signoff dashboards can consume the evidence without reparsing prose logs. The
`evidence-packet-from-corpus-report` command emits `PEXEvidencePacket`, which
keeps inputs, readiness, normalized views, metrics, diagnostics, confidence, and
decision hints together as Agent-readable decision material without prescribing
the repair flow. `evidence-packet-from-extractor-report` emits the same packet
shape from retained Magic/OpenRCX-style real-extractor reports, separating
extractor readiness from physical-bound mismatch diagnostics so an Agent can
decide whether to inspect the toolchain, the raw artifacts, or the design impact.
The retained Magic extractor lane includes `tt` and `ss` corner evidence plus
RC-network resistance coverage, and its report preserves input/output
`artifactRefs` with SHA-256 and byte counts so downstream planning can verify
layout, netlist, technology, manifest, and normalized `ParasiticIR` provenance.

## Metric Recovery Objective

`pexengine metric-recovery-objective` converts retained PEX evidence into an
Agent-readable planning artifact without depending on a UI or an external flow
wrapper. It accepts `pex-summary`, optional `pex-ir-comparison-report`, optional
post-layout metric report JSON, and optional layout / netlist / technology refs.
The output is `pex-metric-recovery-planning-problem`, a structured artifact with
input hashes, objectives, parasitic hotspots, candidate action metadata, and
verification gates.

```bash
pexengine metric-recovery-objective \
  --summary /tmp/pex-summary.json \
  --comparison /tmp/pex-ir-comparison.json \
  --metric-report /tmp/post-layout-metrics.json \
  --layout /tmp/layout.gds \
  --source-netlist /tmp/source.spice \
  --technology /tmp/pex-tech.json \
  --out /tmp/pex-recovery-planning-problem.json \
  --json
```

The metric report reader intentionally consumes only the fields needed for PEX
recovery decisions, so it can read both post-layout comparison reports and
simulation metric summaries. This keeps PEXEngine independent while still giving
Agent callers enough evidence to decide whether to inspect parasitic hotspots,
adjust layout or sizing, rerun PEX, or rerun the post-layout metric gate.

## Artifact Output

Each extraction run produces immutable artifacts:

```
<run-id>/
  manifest.json          # Run metadata, request hash, timestamps
  request.json           # Original request
  raw/<corner-id>/       # Backend-native files (SPEF/DSPF/logs)
  ir/<corner-id>.json    # Normalized IR per corner
  reports/summary.md     # Human-readable summary
```

Loading a run reconstructs corner results from the manifest rather than assuming default paths. Successful corners retain their IR, raw output files, log file paths, and extractor multi-corner comparison summaries; failed corners retain raw and log evidence even when no IR artifact exists.

## License

MIT License. See [LICENSE](LICENSE) for details.
