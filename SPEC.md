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
- FR-008: Persist structured source-netlist connectivity diagnostics per corner.
- FR-009: Emit deterministic canonical-IR SPICE backannotation artifacts.
- FR-010: Retry failed corners from captured run artifacts with parent-run provenance.
- FR-011: Compose a retained ParasiticIR artifact into a source SPICE deck with source-port and hierarchy validation.
- FR-012: Expose parent-to-leaf retry lineage and an effective merged corner view without mutating prior artifacts.

### 2.2 Non-functional requirements
- NFR-001: Deterministic request hashing and traceable artifacts.
- NFR-002: Clear typed errors per stage.
- NFR-003: No backend-specific model leakage through public API.
- NFR-004: Concurrency-safe orchestration.
- NFR-005: Extensible format/backends with minimal core changes.
- NFR-006: A retry must remain reproducible from immutable captured inputs and must not mutate its parent run.

## 3. Scope

### In scope (v1)
- RC extraction orchestration with resistor, capacitor, coupling-capacitor, and inductor IR elements.
- SPEF parser (required), DSPF parser (recommended in v1.x), and extracted-SPICE parsing for Magic.
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

2. Technology normalization (currently split between `PEXCore` models and
   `PEXRuntime/TechnologyResolver`; a dedicated `PEXTech` target remains an
   architectural follow-up)
- Technology resolvers, JSON/inline loader, `TechnologyIR` validation.

3. `PEXRuntime`
- Orchestration actor, pipeline, artifact persistence, run state machine.

4. `PEXParsers`
- `SPEFParser`, `DSPFParser`, parser registry.

5. `PEXAdapters`
- Production adapter protocols and external-tool implementations.
- Optional proprietary adapters in separate packages.

6. `PEXCLI`
- Executable target exposing `pexengine` command.

7. `PEXTestSupport` (test helper target)
- Fixtures, golden loaders, compliance test utilities.

## 5. Public API Design

### 5.1 Primary engine protocol
```swift
public protocol PEXExecuting: Engine<PEXRunRequest, PEXRunResult> {
    func run(_ request: PEXRunRequest) async throws -> PEXRunResult
    func retryFailedCorners(_ request: PEXRunRequest,
                            from previousResult: PEXRunResult) async throws -> PEXRunResult
}
```

### 5.2 Service facade for host applications
```swift
public protocol PEXService {
    func extract(for selection: LayoutSelection,
                 corners: [PEXCorner],
                 backend: PEXBackendSelection) async throws -> PEXRunResult

    func loadRun(_ runID: PEXRunID) throws -> PEXRunResult
    func loadLineage(_ runID: PEXRunID) throws -> PEXRunLineage
    func queryNet(_ net: NetName, runID: PEXRunID, corner: PEXCornerID, workspace: URL) throws -> NetParasiticSummary
    func moduleSummary(_ module: InstancePath, runID: PEXRunID, corner: PEXCornerID, workspace: URL) throws -> PEXModuleParasiticSummary
    func cornerDelta(runID: PEXRunID, baseCorner: PEXCornerID, targetCorner: PEXCornerID, workspace: URL) throws -> PEXCornerDelta
}
```

### 5.3 Adapter protocol
```swift
public protocol PEXExtracting: Sendable {
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
- `technologyByCorner: [String: TechnologyInput]` (optional; overrides the run-level technology for named corners)
- `processProfile: PEXProcessProfileReference?`
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
- `sourceConnectivityPolicy: disabled | warn | strict`

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
- INV-006: Net names and node names within a net must be unique.
- INV-007: Net aggregate values must be finite and non-negative; optional node coordinates must be finite.

## 8. Technology Input and Normalization

### 8.1 Supported technology input styles
- Style A: JSON file (`tech.json`) for app workflows and CLI/CI reproducibility.
- Style B: Inline `TechnologyIR` for programmatic usage.

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
3. Merge optional overlays (local overrides) when an overlay loader is
   provided; the current v1 JSON/inline resolver has no overlay syntax yet.
4. Validate required fields and semantic layer/via/map constraints in strict mode.
5. Emit `TechnologyIR` + diagnostics.

### 8.4 Loader policy
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
- `runs/<run-id>/inputs/process-profile-decks/` (captured RC decks when declared)
- `runs/<run-id>/inputs/request.json` (captured request and input artifact references)
- `runs/<run-id>/raw/<corner-id>/`
- `runs/<run-id>/ir/<corner-id>.json`
- `runs/<run-id>/raw/<corner-id>/extraction.log`
- `runs/<run-id>/spef/<corner-id>.spef` (best-effort canonical round-trip)
- `runs/<run-id>/spice/<corner-id>.cir` (deterministic canonical-IR backannotation fragment)
- `runs/<run-id>/reports/source-connectivity/<corner-id>.json`
- `runs/<run-id>/reports/summary.md`

Failed or partial runs may be retried with `PEXExecuting.retryFailedCorners`.
The retry creates a new immutable run directory containing only the failed
corners and records `resumedFromRunID` in both `manifest.json` and
`PEXRunResult`; successful prior-corner artifacts remain immutable in the
parent run.
`PEXArtifactStore.loadLineage()` follows `resumedFromRunID` links and overlays
newer corner results over older results for review and downstream evaluation.

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
- For Verilog sources, parse module ports/declarations and basic instance
  connections before connectivity comparison; malformed syntax yields warning.
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
- `adapterUnavailable`
- `backendExecutionFailed`
- `cancelled`
- `parseFailed`
- `irValidationFailed`
- `persistenceFailed`
- `internalInvariantViolation`

## 13. Standalone CLI Design

The package must ship an executable command: `pexengine`.

### 13.1 Command overview
- `pexengine extract`
- `pexengine retry`
- `pexengine backannotate`
- `pexengine lineage`
- `pexengine parse`
- `pexengine validate-tech`
- `pexengine summarize`
- `pexengine query`
- `pexengine list-backends`
- `pexengine doctor`

### 13.2 Global options
- `--config <path>`: project config JSON path.
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
- `--corner-technology <id>=<path>` (repeatable)
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

### 13.5 `retry` command
Purpose: retry only failed corners from an immutable persisted run.

Options:
- `--run <path>`: parent `manifest.json` path.
- `--json`: emit the same structured result summary as `extract --json`.

The command reconstructs the request from the parent run's captured layout,
source-netlist, technology, and process-profile deck artifacts. It does not
require the original external input paths to remain available.

### 13.6 `backannotate` command
Purpose: create a runnable source deck containing a retained canonical PEX
fragment and an instance connected to the source netlist ports.

Options:
- `--netlist <path>`: source SPICE netlist.
- `--ir <path>`: retained ParasiticIR JSON artifact.
- `--output <path>`: output netlist path.
- `--top-cell <name>`: optional source subcircuit in which to place the PEX instance.
- `--json`: emit a machine-readable report.

The command fails when generated pin ports do not appear in the source deck or
when the requested top-cell boundary cannot be found.

### 13.7 `validate-tech` command
Purpose: load technology input and validate conversion to `TechnologyIR`.

Options:
- `--technology <path>`
- `--strict`

Output:
- validation report,
- normalized field summary,
- non-zero exit on fatal schema errors.

### 13.8 `lineage` command
Purpose: report the effective corner result after one or more selective retry
runs.

Options:
- `--run <path>`: leaf `manifest.json` path.
- `--json`: emit `PEXRunLineage` JSON.

The JSON result includes `effectiveCorners`, where each selected corner records
the source run ID, retained artifact IDs, status, and failure provenance. This
keeps retry overlays auditable without mutating the parent manifest.

### 13.9 `summarize` command
Purpose: summarize existing run artifacts.

Options:
- `--run <run-id|path>`
- `--top-nets <n>`
- `--corner <id>` (optional filter)

### 13.10 `query` command
Purpose: expose the typed `PEXService` query surface to agents and
developer-operated scripts without requiring an app process.

Exactly one query mode is required:
- `--net <name> --corner <id>`: return `NetParasiticSummary`.
- `--module <instance-path> --corner <id>`: return
  `PEXModuleParasiticSummary`.
- `--base-corner <id> --target-corner <id>`: return `PEXCornerDelta`.

Common options:
- `--run <run-directory|manifest.json>`: persisted run to inspect.
- `--json`: emit `{ "query": ..., "result": ... }` for structured consumers.

The command validates the run manifest and artifact integrity before loading
the requested IR, so a stale or tampered artifact fails as a typed persistence
error instead of returning an unverifiable result.

### 13.11 `list-backends` command
Purpose: enumerate registered backends and capabilities.

### 13.12 `doctor` command
Purpose: environment diagnostics.
- checks executable presence,
- permissions,
- writable workspace,
- parser registry status.

### 13.13 Exit codes
- `0`: success
- `1`: usage/config error or unavailable backend
- `2`: technology resolution failure
- `3`: backend execution failure
- `4`: parse/IR validation failure
- `5`: persistence/internal failure

## 14. Config Schema (JSON)

Configuration is loaded from JSON with a deterministic provider hierarchy:
1. CLI flags (highest precedence)
2. JSON config file (`--config <path>`)
3. In-memory defaults (lowest precedence)

JSON config top-level keys:
- `topCell`
- `inputs.layout`, `inputs.netlist`, `inputs.technology`
- `inputs.technologyByCorner` (optional corner ID → technology JSON path map)
- `backendID`
- `corners` (array of corner ID strings)
- `processProfile.profileID`, `processProfile.pdkRoot`, `processProfile.primaryDeckPath`
- `processProfile.cornerDeckPaths` (corner ID → physical extraction deck path; required for a backend-specific multi-corner sweep when the backend has no native sweep)
- `options.includeCouplingCaps`, `options.maxParallelJobs`, `options.strictValidation`
- `options.sourceConnectivityPolicy` (`disabled`, `warn`, or `strict`)
- `output.workspace`

Required fields:
- `inputs.layout`
- `inputs.netlist`
- `topCell`
- `inputs.technology`
- at least one entry in `corners`

For a backend such as Magic that does not provide a native corner sweep, every
requested corner must resolve to an existing `cornerDeckPaths` file with distinct
content. Reusing one deck, including copying it to a second path, is rejected
rather than reported as physical corner variation.
Relative process-profile paths are resolved against the directory containing
the JSON config file.

The external-oracle qualification corpus also supports a multi-corner case with
`corners`, `cornerDeckPaths`, `technologyByCorner`, and
`requireDistinctCornerDecks`. Its report must contain a comparable multi-corner
summary and the SHA-256 of every
deck and technology input before the case can qualify. Different process decks
(for example, Sky130A versus Sky130B) are allowed only when the corresponding
per-corner TechnologyIR is explicitly provided. This proves process-specific
routing, not PVT equivalence. The persisted
`extractorRun.multiCorner.comparisonBasis` is `perCornerTechnology` for this
case and `sharedTechnology` when all corners use the run-level technology;
`unknown` is encoded explicitly when the current execution cannot establish the basis. Consumers must use
this typed scope together with `comparisonStatus` before promoting a spread to
a PVT signoff claim. `extractorRun.multiCorner.notes` remains a human-readable
diagnostic. PVT claims still require foundry-qualified decks and correlation
data.

## 15. Integration Contract for Host Apps

Host app responsibilities:
- Provide concrete file paths for layout/netlist.
- Provide cell/module selection context.
- Store run-id references for later inspection.
- Select the process profile, extraction options, and workspace through `LayoutSelection` when using the service facade.

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
- artifact-only retry reconstruction and parent-run provenance.

## 18. Implementation Milestones
- M1: Core domain, run model, error model, mock adapter.
- M2: Runtime actor + persistence + deterministic manifests.
- M3: SPEF parser + IR validator + `extract`/`parse` CLI commands.
- M4: technology resolvers (`tech.json`, inline) + `validate-tech` + deterministic JSON configuration loading.
- M5: summarize/list-backends/doctor commands + integration API stabilization.

## 19. Acceptance Criteria (Detailed)
- AC-001: A single CLI command can run extraction end-to-end and produce artifacts.
- AC-002: The same request yields same request hash across runs.
- AC-003: Host apps consume canonical IR without backend-conditional logic.
- AC-004: At least one parser (SPEF) passes golden tests.
- AC-005: Technology input is accepted from at least two styles and normalized to one `TechnologyIR`.
- AC-006: CLI exposes stable exit codes and JSON output for CI automation.
- AC-007: A persisted partial/failed run can retry only failed corners from captured inputs and record `resumedFromRunID`.
- AC-008: Each successful corner emits deterministic SPICE backannotation containing all canonical positive R/C/coupling/L elements.
- AC-009: Source-netlist connectivity policy produces a structured report with disabled, warning, and strict outcomes.
- AC-010: Backannotation composition validates source ports and inserts the PEX instance within the requested source hierarchy boundary.
