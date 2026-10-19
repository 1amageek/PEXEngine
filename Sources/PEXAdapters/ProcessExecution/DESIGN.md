# ProcessExecution

## Purpose and Scope
Owns PEX caller cancellation observation for optional external process execution. Parent: [PEXAdapters](../DESIGN.md). No children.

## Responsibilities and Boundaries
Convert the existing async PEX cancellation check into the public SignoffToolSupport memory control. The process runner owns process timeout, bounded output and tree cleanup. PEX owns and joins its cooperative observation task; no process implementation is duplicated.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [PEXAdapters](../DESIGN.md) | parent | External backend execution | Shared process call boundary | Native calculation does not use this boundary |
| [SignoffToolSupport](../../../../SignoffToolSupport/DESIGN.md) | depends on | TimedProcessRunning, control and structured failures | Process lifetime and cleanup owner | Pending cleanup and retained failure bytes remain explicit |

## Architecture
```mermaid
flowchart LR
  Check[Cooperative PEX async check] --> Monitor[Joined observation task]
  Monitor --> Control[TimedProcessControl]
  Control --> Runner[Signoff process runner]
  Runner --> Result[Actual bytes or structured failure]
```

## Contracts and Invariants
An initial check can refuse before process launch. A monitor requests cancellation or records its original callback failure in memory; it does not throw away process failure output. Both tasks are joined. Callback cancellation must cooperate with Task cancellation, matching the existing native monitor contract; an uncooperative caller callback is not included in the runner's process-timeout guarantee. External adapters use injectable runners with explicit defaults of 64 MiB aggregate output and five seconds cleanup; these are finite operational policy, not process qualification. Custom runners can select other valid budgets.

## State, Ownership, and Lifecycle
One call owns one memory control and task group. Control state uses the Support-owned Mutex and shares identical host storage/access. No pointer, actor stream or detached task escapes.

## Failure, Concurrency, and Constraints
Support structured failures preserve cause, bytes and pending cleanup handles. The caller boundary retries pending close once under a five-second budget; if it remains incomplete, PEXProcessCleanupFailure retains the live handle and original cause/output. Adapter failure retains that live error. After joining all corners, Runtime transfers pending ownership to its caller instead of converting it to a persisted failed result and dropping the handle. Persisted diagnostics do not claim cleanup completion. Callback error requests controlFailed; genuine cancellation remains cancelled. No I/O or callback executes under a lock.

## Verification and Change Impact
Magic/OpenRCX adapter process cancellation/timeout tests and NativePEXAdapterTests actual executable tests exercise the adopted public runner. Changes affect both external process consumers only.
