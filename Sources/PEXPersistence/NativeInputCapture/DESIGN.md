# NativeInputCapture

## Purpose and Scope
Owns bounded reading and exact manifest associations for native configuration/calibration files. Parent: [PEXPersistence](../DESIGN.md). No children.

## Responsibilities and Boundaries
Read local regular files in bounded chunks, preserve the snapshot bytes, and verify each calibration SHA-256/byte count before execution. Recorder/store composition roots own manifest publication. Domain schema interpretation and calibration qualification remain external.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [PEXPersistence](../DESIGN.md) | parent | Recorder/store/resolver integrity | Snapshot lifetime | Captured requests resolve by role/identity rather than source location |
| [NativeInput](../../PEXCore/NativeInput/DESIGN.md) | depends on | Native references and budgets | Bounded source admission | Identity is separate from file availability |
| [PEXRuntime](../../PEXRuntime/DESIGN.md) | used by | Captured native inputs | Pre-execution provenance | Validate required model calibration coverage after technology resolution |

## Architecture
```mermaid
flowchart LR
  Source[Local native input] --> Read[Bounded regular-file read]
  Read --> Verify[Calibration digest/count match]
  Verify --> Save[Immutable run-local bytes]
  Save --> Manifest[Exact role and content identity]
  Manifest --> Reload[Verified captured references]
```

## Contracts and Invariants

The additive native configuration kind is preserved during run-local location
replacement and replay. Routed rule/technology/library sources reuse the existing
unique calibration identity records and their byte budgets. Schema interpretation
and full source-reference authority binding remain with the
[NativeInput](../../PEXCore/NativeInput/DESIGN.md) and
[RoutedInputPreparation](../../PEXAdapters/NativeBackend/RoutedInputPreparation/DESIGN.md)
owners; capture does not manufacture an analytical calibration model.
Reads stop at the selected byte ceiling and reject excess, directories and missing files. A successful capture stores exactly the bytes used for content identity. Configuration uses a stable semantic role; calibration record identity is derived from full digest and byte count, never a source filename. Reload and initial captured-request reconstruction require exactly one available record per role/identity, then verify stored bytes through existing integrity owners. Reconstruction rejects missing input files even when the aggregate manifest status allows partially available output; input-specific integrity evidence is reused. Configuration/reference reconstruction is performed once for request recording and initial execution. Calibration bytes use the raw format descriptor; their semantic schema is not inferred from a filename. Run-local path replacement does not change content identity.

## State, Ownership, and Lifecycle
A FileHandle belongs to one bounded synchronous read and is closed on success/failure; close failure is explicit. No shared mutable state or pointers. Peak input buffer is bounded by the admitted single-file ceiling plus one read chunk. Aggregate calibration byte budgets include all declared artifacts.

## Failure, Concurrency, and Constraints
Malformed references, unreadable files, exceeded budgets, missing/duplicate records and digest/count mismatch fail with typed PEX input/persistence errors. No external source fallback is permitted during reconstruction. The reader opens local inputs nonblocking, checks regular-file type on the opened descriptor before reading, and rejects special files without waiting for a writer. It does not claim hostile path-tree authorization or power-loss durability.

## Verification and Change Impact
Public capture/run/load behavior is covered by PEXRuntimeTests/PEXNativeInputCaptureTests and bounded-reader tests in PEXPersistenceTests. Native configuration schema and actual extraction require their own evidence.
