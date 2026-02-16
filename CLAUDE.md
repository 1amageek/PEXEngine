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

- Swift Tools Version: **6.2** (requires Swift 6.2+, macOS 26+)
- Test framework: **Swift Testing** (`import Testing`, `@Test`, `#expect`)  — not XCTest
- No external dependencies
- 91 tests across 10 test suites

## Architecture

The package is designed around a pipeline: `PEXRunRequest` → adapter execution → raw output parsing → canonical IR → artifact persistence → `PEXRunResult`.

### Module Structure

| Module | Responsibility | Files |
|---|---|---|
| **PEXCore** | Domain models, IR, protocols, typed errors, registries, validation | ~53 files |
| **PEXAdapters** | Backend adapters (`MockPEXAdapter`, `ProcessRunner`) | 3 files |
| **PEXParsers** | SPEF lexer/parser/lowering pipeline | 7 files |
| **PEXPersistence** | Manifest, workspace, IR serializer, artifact store, report generator | 5 files |
| **PEXRuntime** | Orchestrator (actor), pipeline, technology resolver, config mapper, default engine | 5 files |
| **PEXEngine** | Umbrella module (`@_exported import` of all above) | 1 file |
| **PEXCLICore** | CLI command logic: router, commands, formatter (testable library) | 8 files |
| **PEXCLI** | Thin executable entry point (imports PEXCLICore) | 1 file |

### Core Protocols

- **`PEXEngineProtocol`** — `func run(_ request: PEXRunRequest) async throws -> PEXRunResult`
- **`PEXAdapter`** — `prepare`/`execute`/`cleanup` lifecycle with `PEXBackendCapabilities`
- **`PEXParserProtocol`** — parses `PEXRawOutput` into `ParasiticIR` via `PEXParseContext`
- **`PEXService`** — host app integration (`extract(for:corners:backend:)`)

### Canonical IR (`ParasiticIR`)

Tool-independent representation with three element types:
- `resistor(nodeA, nodeB, valueOhm)`
- `capacitor(nodeA, nodeB?, valueF)` — `nodeB=nil` means ground cap
- `coupling(nodeA, nodeB, valueF)`

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
- **MockPEXAdapter is mandatory** — used for all tests, preview, and development
- Adapters must declare capability flags (coupling, corner sweep, RC reduction, incremental)

## Artifact Output Structure

Each run produces immutable artifacts:
```
<run-id>/
  manifest.json    # request hash, backend version, timestamps
  raw/             # backend-native files (SPEF/DSPF/logs)
  ir/              # normalized IR per corner
  reports/summary.md
```

## Milestones

1. **M1** (Complete): Core domain + Mock adapter + SPEF parser + IR validator + JSON persistence + CLI + multi-corner orchestration
2. **M2**: DSPF parser + additional output format support
3. **M3**: Real backend adapter integration (Calibre/StarRC/Quantus)
4. **M4**: semiconductor-layout integration adapter
