# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PEXEngine is a Swift package that executes parasitic extraction (PEX) for semiconductor layouts. It normalizes extracted parasitics into a tool-agnostic IR and provides results to host applications like `semiconductor-layout`. See `SPEC.md` for the full design specification.

## Build & Test Commands

```bash
# Build
swift build

# Run all tests
swift test

# Run specific module tests
swift test --filter PEXCoreTests
swift test --filter PEXAdaptersTests
swift test --filter PEXParsersTests
swift test --filter PEXPersistenceTests
swift test --filter PEXRuntimeTests
swift test --filter PEXCLITests

# CLI verification
swift run pexengine --version
swift run pexengine extract --config <path-to-config.json> --json

# Build for release
swift build -c release
```

- Swift Tools Version: **6.3** (requires Swift 6.3+, macOS 26+)
- Test framework: **Swift Testing** (`import Testing`, `@Test`, `#expect`)  — not XCTest
- CLI configuration uses Foundation JSON loading with file-over-default precedence; no external configuration package is required.
- Swift Testing suites cover core models, adapters, parsers, persistence, runtime, and CLI contracts.

## Architecture

The package is designed around a pipeline: `PEXRunRequest` → adapter execution → raw output parsing → canonical IR → artifact persistence → `PEXRunResult`.

### Module Structure

| Module | Responsibility | Files |
|---|---|---|
| **PEXCore** | Domain models, IR, protocols, typed errors, registries, validation | ~53 files |
| **PEXAdapters** | Production backend integrations (`MagicPEXAdapter`, `MagicToolchain`, process execution, default backend registry) | tracked |
| **PEXTestSupport** | Test-only synthetic extraction and deterministic fixture generation | tracked |
| **PEXParsers** | SPEF lexer/parser/lowering pipeline, SPEF writer, deterministic SPICE backannotation writer/composer, Magic SPICE parasitic parser | tracked |
| **PEXPersistence** | Manifest, workspace, IR serializer, artifact store, report generator | 5 files |
| **PEXRuntime** | Orchestrator (actor), pipeline, technology resolver, config mapper, source-connectivity parsers, default engine | tracked |
| **PEXEngine** | Umbrella module (`@_exported import` of all above) | 1 file |
| **PEXCLICore** | CLI command logic: router, commands, formatter (testable library) | tracked |
| **PEXCLI** | Thin executable entry point (imports PEXCLICore) | 1 file |

### Core Protocols

- **`PEXExecuting`** — extraction plus selective failed-corner retry with `resumedFromRunID` provenance
- **`PEXExtracting`** — `prepare`/`execute`/`cleanup` lifecycle with `PEXBackendCapabilities`
- **`PEXParsing`** — parses `PEXRawOutput` into `ParasiticIR` via `PEXParseContext`
- **`PEXService`** — host app integration (`extract(for:corners:backend:)`)

### Canonical IR (`ParasiticIR`)

Tool-independent representation with four element types:
- `resistor(nodeA, nodeB, valueOhm)`
- `capacitor(nodeA, nodeB?, valueF)` — `nodeB=nil` means ground cap
- `coupling(nodeA, nodeB, valueF)`
- `inductor(nodeA, nodeB, valueH)`

### SPEF Parser Pipeline

3-stage architecture: `SPEFLexer` (source → tokens) → `SPEFParser` (tokens → `SPEFParseTree`) → `SPEFLowering` (parse tree → `ParasiticIR` with unit normalization)

### Concurrency Model

- `PEXOrchestrator` is an **`actor`** — I/O operations + ordered state transitions
- `PEXAdapterRegistry` / `PEXParserRegistry` use **`Mutex<T>`** — synchronous memory access only
- Multi-corner extraction uses **`TaskGroup`** with bounded parallelism (`maxParallelJobs`)
- All data models are **`Sendable`** structs

### Error Model

Typed `PEXError` with 8 categories: `invalidInput`, `technologyResolutionFailed`, `adapterUnavailable`, `backendExecutionFailed`, `parseFailed`, `irValidationFailed`, `persistenceFailed`, `internalInvariantViolation`. Each error carries stage, backend/corner context, and descriptive message.

### Integration with circuit-studio

circuit-studio's `PEXCommandService` invokes: `pexengine extract --config <path>`
- `PEXProjectConfig` is structurally identical between both packages for JSON interop
- Exit codes: invalidInput=1, technologyFailed=2, backendFailed=3, parseFailed=4, persistenceFailed=5

## Key Design Constraints

- **`try?` is prohibited** — use `do-catch` or `throws` for proper error handling
- **Value types first** — use `struct` for data; `class` only when reference semantics are required
- **One file, one type** — each file contains one primary type
- **Protocol-oriented** — public interfaces defined as protocols, implementations separate
- **Dependencies injected** via protocols for testability
- **Synthetic extraction is test-only** — production defaults register only physical extraction backends; deterministic synthetic extraction lives in `PEXTestSupport`
- Adapters must declare capability flags (coupling, corner sweep, RC reduction, incremental)

## Artifact Output Structure

Each run produces immutable artifacts:
```
<run-id>/
  manifest.json    # request hash, backend version, timestamps
  raw/             # backend-native files (SPEF/DSPF/logs)
  spice/           # deterministic SPICE backannotation fragments per corner
  ir/              # normalized IR per corner
  reports/summary.md
```

## Milestones

1. **M1** (Complete): Core domain + Mock adapter + SPEF parser + IR validator + JSON persistence + CLI + multi-corner orchestration
2. **M2** (Complete for SPEF/DSPF/extracted-SPICE): DSPF hierarchy/annotation lowering, inductor preservation, and parser/report CLI support
3. **M3** (Complete for Magic): real backend adapter — `MagicPEXAdapter` + `MagicSPICEParasiticParser` run Magic parasitic extraction end to end; Magic declares `supportsCornerSweep=false` for native sweep, while explicit per-corner extraction decks and `technologyByCorner` provide a qualified process-corner path; Calibre/StarRC/Quantus adapters remain open
4. **M4** (Partial): PEX emits a deterministic canonical-IR SPICE fragment, supports hierarchy-aware `backannotate`, artifact-only failed-corner retry, and merged lineage; foundry signoff breadth remains open
