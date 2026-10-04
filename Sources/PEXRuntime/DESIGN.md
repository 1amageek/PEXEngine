# PEXRuntime

## Purpose and Scope
Composes extraction request validation, captured-input resolution, backend corner execution, canonical admission, artifact persistence and run lineage. Parent: [PEXEngine](../../DESIGN.md). No child introduced by the execution-payload change.

## Responsibilities and Boundaries
PEXOrchestrator and PEXPipeline are module composition roots. They consume public backend/parser/persistence contracts, retain available evidence on failure and bind every successful result to its executing backend/corner. Numerical extraction, standard codec semantics, filesystem artifact integrity and process qualification remain with their owners.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [PEXEngine](../../DESIGN.md) | parent | Run lifecycle and artifacts | Package composition | Complete native run requires captured native inputs/calibration |
| [BackendExecution](../PEXCore/BackendExecution/DESIGN.md) | depends on | Typed raw/canonical payload and identity | Corner execution boundary | Raw files do not imply external invocation |
| [PEXNative](../PEXNative/DESIGN.md) | coordinates with | Native canonical graph | Future actual backend registration | A fileless test adapter is not native backend proof |
| [PEXCore](../PEXCore/DESIGN.md) | depends on | Exact requests/corners and IR | Domain admission | Do not infer connectivity from name coverage |

## Architecture
```mermaid
flowchart TD
  Request --> Capture[Capture and resolve exact inputs]
  Capture --> Corner[Prepare and execute adapter]
  Corner --> Identity[Bind producer and corner]
  Identity --> Raw[Raw payload: retain files and parse]
  Identity --> Canonical[Canonical payload: consume graph directly]
  Raw --> Validate[Common IR admission]
  Canonical --> Validate
  Validate --> Persist[IR + optional standard exports + manifest]
  Corner --> Failure[Retain observed identity and available evidence]
  Failure --> Persist
```

## Contracts and Invariants
No parser or synthetic raw file is required for canonical payloads. Actual raw files/logs are retained only for raw payloads; generated evidence remains retained in both paths. Exact corner mismatch and backend/expected-producer mismatch fail explicitly. Canonical graph admission validates once at the immutable backend-result boundary; runtime reuses its derived warning evidence. Canonical graph validation cannot be disabled by non-strict raw-parser options. Cross-corner producer/image identity and invocation mode/entrypoint remain consistent. Standard writer warnings and input retention are existing separately owned gaps until their integration work closes them; this payload change does not claim complete native run/resume.

## Runtime Flows
Validate/capture request, resolve captured technology, execute corners under existing concurrency policy, retain output evidence, select raw parsing or canonical graph by payload, validate, persist, aggregate exact execution identities and save manifest. Existing public load reconstructs canonical IR and an empty raw-output list for fileless results without depending on raw files.

## State, Ownership, and Lifecycle
Call-local run/corner state retains immutable input and output values. Artifact recording appends each verified record directly to the corner-owned retention buffer, so a later failure cannot discard an earlier record. Adapter cleanup follows success/failure. No new shared state, stream or resource lifetime is introduced by payload selection.

## Failure, Concurrency, and Constraints
Failed canonical admission retains generated evidence and observed identity and publishes a failed corner with no IR. Mixed identities fail whole-run aggregation. Existing bounded process/corner ownership remains unchanged. Cancellation and measured native-image retention are verified by the actual backend owner in subsequent composition work.

## Verification and Change Impact
PEXCanonicalExecutionTests proves real public orchestration/persistence/reload dispatch with a fileless in-process contract fixture and failure cases. Existing raw adapter/runtime tests prove raw parsing/evidence paths still execute. Changes to backend result types affect all adapters; native inputs, registration, standard exports, CLI and resume require cumulative integration after their own implementations converge.
