# PEXEngine

A Swift package for parasitic extraction (PEX) of semiconductor layouts. PEXEngine orchestrates extraction backends, parses their outputs, and normalizes results into a tool-agnostic canonical IR.

## Features

- **Backend-agnostic pipeline** -- Abstracts extraction tools behind a unified adapter protocol
- **Canonical Parasitic IR** -- Tool-independent representation of resistors, capacitors, and coupling elements
- **SPEF parser** -- 3-stage pipeline: lexer, parser, lowering with unit normalization
- **Multi-corner extraction** -- Parallel corner processing with configurable job limits
- **Immutable artifact persistence** -- Manifest, raw outputs, normalized IR, and summary reports
- **CLI tool** -- `pexengine` commands for extraction, parsing, validation, and diagnostics
- **Fully testable** -- 91 tests across 10 suites, zero external dependencies

## Requirements

- Swift 6.2+
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
[ PEXAdapter ]         --> PEXRawOutput (SPEF/DSPF)
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
| **PEXParsers** | SPEF lexer / parser / lowering pipeline |
| **PEXPersistence** | Manifest, workspace layout, IR serializer, artifact store, report generator |
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

// Query parasitic data
let service = DefaultPEXService.withDefaults()
let summary = try service.queryNet(
    NetName("VDD"),
    runID: result.runID,
    corner: PEXCornerID("tt_25c_1v0"),
    workspace: workspaceURL
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

# Parse a SPEF file
pexengine parse --input output.spef --corner tt --json

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

## License

MIT License. See [LICENSE](LICENSE) for details.
