# NativeInputLoading

## Purpose and Scope
Owns shared native backend admission and bounded loading of a selected reference
document. Parent: [PEXRuntime](../DESIGN.md). No children.

## Responsibilities and Boundaries
PEXNativeInputLoading is the public service contract; PEXNativeInputLoader is its
stateless implementation. It reads and decodes one local document. Native
configuration interpretation, calibration verification, capture, numerical
extraction, producer measurement and retry remain with their existing owners.

## Related Designs
| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [PEXRuntime](../DESIGN.md) | parent | Config mapping and run composition | Shared service owner | Config paths resolve at the document base |
| [PEXCLICore](../../PEXCLICore/DESIGN.md) | used by | Selected reference URL | CLI admission | Explicit CLI path overrides config selection |
| [Core NativeInput](../../PEXCore/NativeInput/DESIGN.md) | depends on | Codable validated reference | Required fields and budgets | No URL rewriting or alternate schema |
| [NativeInputCapture](../../PEXPersistence/NativeInputCapture/DESIGN.md) | depends on | Bounded regular-file read | Read and close failures | Content verification belongs to later capture |

## Architecture
```text
Backend + selected local document URL -> shared admission
 -> bounded reader (4 MiB) -> Core JSONDecoder -> unchanged typed reference
```

## Contracts and Invariants

The additive configuration kind is retained unchanged according to
[NativeInput](../../PEXCore/NativeInput/DESIGN.md). The same loader and reference
document entry point serve mask and explicitly routed native inputs; loading does
not reinterpret a routed schema, infer a corner or convert a native law.
Native selection requires a reference URL. Other backends reject a supplied
reference. The document has a finite four-MiB ceiling and must be local; decoded
configuration/calibration locations and budgets are validated by Core and
preserved exactly. Decode failures are typed invalidInput PEXError; reader errors
retain their typed failure. No implicit reference or alternate schema is used.

## State, Ownership, and Lifecycle
Loading is synchronous, stateless and Sendable. Each read owns and closes its
file handle on success and failure. No mutable shared state or async work is
introduced. Only the reference document is read; Runtime captures the referenced
inputs before execution.

## Failure, Concurrency, and Constraints
Missing, nonlocal, directory, malformed and oversized documents fail explicitly.
Backend mismatch fails before document I/O. The existing reader bounds retained
data and reports close failure. Calibration bytes are verified during capture.

## Verification and Change Impact
PEXRuntimeTests exercises actual mapper loading, unchanged decoded URLs and
backend/path refusal. PEXNativeExtractCommandTests retains direct/config override,
malformed Core reference and exact four-MiB boundary proofs. Existing numerical,
capture, producer, cancellation and retry proofs remain unchanged.
