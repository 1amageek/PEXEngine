# PEXEngine Detailed Specification

## 1. Document Intent
This document defines the detailed design of `PEXEngine` as a generic, reusable, standalone parasitic extraction orchestration package.

Design goals:
- Embed in applications (library mode).
- Run independently from terminal/CI (CLI mode).
- Support multiple extraction backends without app-side branching.
- Normalize heterogeneous backend outputs into one canonical parasitic IR.

## 2. System Requirements

### 2.1 Functional requirements
- FR-001: Accept layout + source netlist + top cell + corner set as input.
- FR-002: Resolve technology configuration from multiple input formats.
- FR-003: Run selected backend adapter and collect raw artifacts.
- FR-004: Parse backend outputs into canonical IR.
- FR-005: Persist reproducible run artifacts and manifest.
- FR-006: Provide API for host app queries (net-level and module-level parasitics).
- FR-007: Provide CLI commands for extraction, parsing, validation, and reporting.

### 2.2 Non-functional requirements
- NFR-001: Deterministic request hashing and traceable artifacts.
- NFR-002: Clear typed errors per stage.
- NFR-003: No backend-specific model leakage through public API.
- NFR-004: Concurrency-safe orchestration.
- NFR-005: Extensible format/backends with minimal core changes.

## 3. Scope

### In scope (v1)
- RC extraction orchestration.
- SPEF parser (required), DSPF parser (recommended in v1.x).
- Technology package normalization into `TechnologyIR`.
- Mock backend for local tests and UI preview.
- Standalone CLI (`pexengine`) with machine-readable output option.

### Out of scope (v1)
- DRC/LVS engines.
- Signoff guarantee for any foundry.
- EM/IR/thermal analysis.
- Remote distributed execution scheduler.

## 4. Package Decomposition

`PEXEngine` should be split into SwiftPM targets:

1. `PEXCore`
- Domain models, errors, IDs, unit types, protocol contracts.

2. `PEXTech`
- Technology resolvers, multi-format loader, `TechnologyIR`.

3. `PEXRuntime`
- Orchestration actor, pipeline, artifact persistence, run state machine.

4. `PEXParsers`
- `SPEFParser`, `DSPFParser`, parser registry.

5. `PEXAdapters`
- Adapter protocols + implementations (`MockAdapter` required).
- Optional proprietary adapters in separate packages.

6. `PEXCLI`
- Executable target exposing `pexengine` command.

7. `PEXTestingSupport` (optional test helper target)
- Fixtures, golden loaders, compliance test utilities.

## 5. Public API Design

### 5.1 Primary engine protocol
```swift
public protocol PEXEngine {
    func run(_ request: PEXRunRequest) async throws -> PEXRunResult
}
```

### 5.2 Service facade for host applications
```swift
public protocol PEXService {
    func extract(for selection: LayoutSelection,
                 corners: [PEXCorner],
                 backend: PEXBackendSelection) async throws -> PEXRunResult

    func loadRun(_ runID: PEXRunID) throws -> PEXRunResult
    func queryNet(_ net: NetName, runID: PEXRunID, corner: PEXCornerID) throws -> NetParasiticSummary
}
```

### 5.3 Adapter protocol
```swift
public protocol PEXAdapter: Sendable {
    var backendID: String { get }
    var capabilities: PEXBackendCapabilities { get }

    func prepare(_ context: PEXExecutionContext) async throws
    func execute(_ context: PEXExecutionContext) async throws -> PEXRawOutput
    func cleanup(_ context: PEXExecutionContext) async
}
```

### 5.4 Parser protocol
```swift
public protocol PEXParser: Sendable {
    var format: PEXOutputFormat { get }
    func parse(_ raw: PEXRawOutput, context: PEXParseContext) throws -> ParasiticIR
}
```

## 6. Domain Model (Detailed)

### 6.1 Identifiers
- `PEXRunID`: UUID-based immutable run identifier.
- `PEXRequestHash`: deterministic hash of canonicalized request.
- `PEXCornerID`: stable string key (`tt_25c_1v0`).
- `NetName`, `NodeName`, `InstancePath`: strongly typed wrappers.

### 6.2 Request object
`PEXRunRequest` fields:
- `layoutURL: URL`
- `layoutFormat: LayoutFormat` (`gds`, `oas`)
- `sourceNetlistURL: URL`
- `sourceNetlistFormat: NetlistFormat` (`spice`, `cdl`, `verilog` optional)
- `topCell: String`
- `corners: [PEXCorner]`
- `technology: TechnologyInput`
- `backendSelection: PEXBackendSelection`
- `options: PEXRunOptions`
- `workingDirectory: URL?`

### 6.3 Run options
- `extractMode: PEXExtractMode` (`rc`, `c_only`, `r_only`)
- `includeCouplingCaps: Bool`
- `minCapacitanceF: Double?`
- `minResistanceOhm: Double?`
- `maxParallelJobs: Int`
- `emitRawArtifacts: Bool`
- `emitIRJSON: Bool`
- `strictValidation: Bool`

### 6.4 Result object
`PEXRunResult`:
- `runID`
- `requestHash`
- `status: PEXRunStatus`
- `startedAt`, `finishedAt`
- `cornerResults: [PEXCornerResult]`
- `warnings: [PEXWarning]`
- `artifacts: PEXArtifactIndex`
- `metrics: PEXRunMetrics`

`PEXCornerResult`:
- `cornerID`
- `status`
- `ir: ParasiticIR?`
- `rawOutputs: [URL]`
- `logURL: URL`
- `metrics: PEXCornerMetrics`

## 7. Canonical Parasitic IR

### 7.1 IR entity graph
`ParasiticIR`:
- `version: String`
- `cornerID: PEXCornerID`
- `units: ParasiticUnits`
- `nets: [ParasiticNet]`
- `elements: [ParasiticElement]`
- `metadata: [String: String]`

`ParasiticNet`:
- `name: NetName`
- `nodes: [ParasiticNode]`
- `totalGroundCapF: Double`
- `totalCouplingCapF: Double`
- `totalResistanceOhm: Double`

`ParasiticNode`:
- `name: NodeName`
- `kind: NodeKind` (`pin`, `internal`, `substrate`, `ground`)
- `instancePath: InstancePath?`
- `xy: Point2D?`

`ParasiticElement`:
- `id: String`
- `kind: ElementKind`
- `a: NodeRef`
- `b: NodeRef?`
- `value: Double`
- `source: ElementSource`

### 7.2 IR invariants
- INV-001: Every element endpoint node must exist.
- INV-002: Ground capacitor uses `b=nil` or explicit global ground node, not both.
- INV-003: Values must be finite and non-negative.
- INV-004: IDs must be unique per corner.
- INV-005: Net membership must be consistent with node namespace.

## 8. Technology Input and Normalization

### 8.1 Supported technology input styles
- Style A: Directory package (decks + layer map + optional cross-section files).
- Style B: JSON overlay (`tech.json`) for app workflows.
- Style C: TOML project config (`pex.toml`) for CLI/CI reproducibility.

### 8.2 Internal normalization target
All styles must resolve to `TechnologyIR`:
- `processName`
- `stack` (layers, ordering, thickness, material metadata)
- `logicalToPhysicalLayerMap`
- `vias`
- `defaultExtractionRules` (thresholds, reduction policy)
- `backendHints` (per-backend mappings)

### 8.3 Resolver chain
1. Detect input style.
2. Parse style-specific schema.
3. Merge optional overlays (local overrides).
4. Validate required fields.
5. Emit `TechnologyIR` + diagnostics.

### 8.4 Compatibility policy
- `TechnologyIR` is the only runtime dependency for core execution.
- New config formats are added as loaders, not by changing runtime contracts.

## 9. Runtime Pipeline

### 9.1 Orchestrator
`PEXOrchestrator` is an `actor` responsible for ordered state transitions and run lifecycle.

State machine:
- `created`
- `validated`
- `prepared`
- `extracting`
- `parsing`
- `validating`
- `persisted`
- `completed`
- `failed`

### 9.2 Per-corner execution model
- Each corner becomes an independent job unit.
- Job units may run in parallel up to `maxParallelJobs`.
- Failures are isolated by corner unless `strictValidation` requires fail-fast.

### 9.3 Persistence contract
Run directory:
- `runs/<run-id>/manifest.json`
- `runs/<run-id>/request.json`
- `runs/<run-id>/corners/<corner-id>/raw/`
- `runs/<run-id>/corners/<corner-id>/ir/ir.json`
- `runs/<run-id>/corners/<corner-id>/logs/extract.log`
- `runs/<run-id>/reports/summary.md`

## 10. Backend Abstraction

### 10.1 Backend capabilities
`PEXBackendCapabilities`:
- `supportsCouplingCaps`
- `supportsCornerSweep`
- `supportsIncremental`
- `supportsRCReduction`
- `nativeOutputFormats: [PEXOutputFormat]`

### 10.2 Adapter registration
`PEXAdapterRegistry`:
- Register by `backendID`.
- Resolve adapter by explicit selection.
- Provide clear error when backend is not available.

### 10.3 External tool execution
`ProcessRunner` abstraction:
- command path resolution,
- env injection,
- timeout/cancellation,
- stdout/stderr capture,
- exit code mapping.

## 11. Parser Architecture

### 11.1 Parser registry
- `PEXParserRegistry` keyed by `PEXOutputFormat`.
- Adapter announces output format.
- Runtime selects parser dynamically.

### 11.2 Validation layer
After parse:
- Apply IR invariants.
- Detect disconnected nodes, duplicate IDs, impossible values.
- Emit `PEXWarning` or throw by policy.

### 11.3 Units policy
- Canonical unit in IR:
  - resistance: Ohm
  - capacitance: Farad
  - coordinates: micrometer
- Parsers must normalize units and preserve original unit metadata.

## 12. Error Model

`PEXError` includes:
- `kind: PEXErrorKind`
- `stage: PEXStage`
- `runID: PEXRunID?`
- `cornerID: PEXCornerID?`
- `backendID: String?`
- `message: String`
- `underlying: Error?`
- `diagnosticFile: URL?`

Error kinds:
- `invalidInput`
- `technologyResolutionFailed`
- `backendUnavailable`
- `backendExecutionFailed`
- `parseFailed`
- `irValidationFailed`
- `persistenceFailed`
- `internalInvariantViolation`

## 13. Standalone CLI Design

The package must ship an executable command: `pexengine`.

### 13.1 Command overview
- `pexengine extract`
- `pexengine parse`
- `pexengine validate-tech`
- `pexengine summarize`
- `pexengine list-backends`
- `pexengine doctor`

### 13.2 Global options
- `--config <path>`: `pex.toml` path.
- `--workspace <path>`: artifact root.
- `--log-level <trace|debug|info|warn|error>`
- `--json`: machine-readable result output.
- `--no-color`

### 13.3 `extract` command
Purpose: full run from layout/netlist to canonical IR.

Required options:
- `--layout <path>`
- `--netlist <path>`
- `--top-cell <name>`
- `--technology <path>`
- `--backend <id>`
- `--corner <id>` (repeatable)

Optional:
- `--max-jobs <n>`
- `--include-coupling`
- `--min-cap-f <value>`
- `--min-res-ohm <value>`
- `--out <path>`
- `--strict`

Output:
- human summary to stdout,
- `--json` emits structured `PEXRunResult` summary object.

### 13.4 `parse` command
Purpose: parse raw backend output to canonical IR.

Options:
- `--format <spef|dspf|custom>`
- `--input <path>`
- `--corner <id>`
- `--out <path>`

### 13.5 `validate-tech` command
Purpose: load technology input and validate conversion to `TechnologyIR`.

Options:
- `--technology <path>`
- `--strict`

Output:
- validation report,
- normalized field summary,
- non-zero exit on fatal schema errors.

### 13.6 `summarize` command
Purpose: summarize existing run artifacts.

Options:
- `--run <run-id|path>`
- `--top-nets <n>`
- `--corner <id>` (optional filter)

### 13.7 `list-backends` command
Purpose: enumerate registered backends and capabilities.

### 13.8 `doctor` command
Purpose: environment diagnostics.
- checks executable presence,
- permissions,
- writable workspace,
- parser registry status.

### 13.9 Exit codes
- `0`: success
- `1`: usage/config error
- `2`: input validation failure
- `3`: backend execution failure
- `4`: parse/IR validation failure
- `5`: persistence/internal failure

## 14. Config Schema (`pex.toml`)

Top-level tables:
- `[project]`
- `[inputs]`
- `[technology]`
- `[runtime]`
- `[output]`
- `[[corners]]`

Required fields:
- `inputs.layout`
- `inputs.netlist`
- `inputs.top_cell`
- `technology.path`
- `runtime.backend`
- at least one `corners.id`

Merge rule:
- CLI flags override `pex.toml`.
- `pex.toml` overrides internal defaults.

## 15. Integration Contract for Host Apps

Host app responsibilities:
- Provide concrete file paths for layout/netlist.
- Provide cell/module selection context.
- Store run-id references for later inspection.

Engine responsibilities:
- Keep app independent from backend format differences.
- Return canonical IR and summary APIs.
- Preserve run reproducibility and diagnostics.

Recommended app query surface:
- `netSummary(net, runID, corner)`
- `moduleSummary(instancePath, runID, corner)`
- `cornerDelta(runID, baseCorner, targetCorner)`

## 16. Security and Compliance
- Never bundle proprietary decks in repository by default.
- Redact sensitive env/path data from user-facing logs.
- Do not auto-download backend binaries silently.
- Allow explicit path pinning for backend executables.

## 17. Test Plan

### 17.1 Unit tests
- Domain model validation.
- Request canonicalization and hash determinism.
- Error mapping per pipeline stage.

### 17.2 Parser golden tests
- Golden SPEF fixtures.
- Unit conversion checks.
- Invariant violation fixtures.

### 17.3 Integration tests
- Mock backend full pipeline.
- Multi-corner partial-failure behavior.
- Artifact layout and manifest integrity.

### 17.4 CLI tests
- command parsing,
- JSON output schema checks,
- exit code correctness,
- workspace persistence behavior.

## 18. Implementation Milestones
- M1: Core domain, run model, error model, mock adapter.
- M2: Runtime actor + persistence + deterministic manifests.
- M3: SPEF parser + IR validator + `extract`/`parse` CLI commands.
- M4: technology resolvers (`tech.json`, `pex.toml`, package directory) + `validate-tech`.
- M5: summarize/list-backends/doctor commands + integration API stabilization.

## 19. Acceptance Criteria (Detailed)
- AC-001: A single CLI command can run extraction end-to-end and produce artifacts.
- AC-002: The same request yields same request hash across runs.
- AC-003: Host apps consume canonical IR without backend-conditional logic.
- AC-004: At least one parser (SPEF) passes golden tests.
- AC-005: Technology input is accepted from at least two styles and normalized to one `TechnologyIR`.
- AC-006: CLI exposes stable exit codes and JSON output for CI automation.

