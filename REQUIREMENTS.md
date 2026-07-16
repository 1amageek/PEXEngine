# PEXEngine Requirements

## Required boundary

- Depend on `CircuiteFoundation` for the engine and cross-engine evidence
  vocabulary.
- Expose `PEXExecuting` as a Foundation `Engine` contract.
- Make `PEXRunResult` directly provide `EvidenceManifest`,
  `ArtifactReference`, `ExecutionProvenance`, and typed diagnostics.
- Reject available artifact records without a valid SHA-256 or byte count.
- Preserve immutable manifests, retry lineage, corner status, and typed
  extraction failures.
- Provide `PEXRunRequest.designObjectReference()` for top-cell addressing.

## Non-goals

- Foundation does not own parasitic semantics, parser behavior, or backend
  discovery.
- PEX does not own project lifecycle or approval policy.
- An artifact path alone is not evidence of artifact integrity.

## Verification

`swift build` must pass. PEX tests must continue to cover parsers, IR
validation, technology resolution, adapters, multi-corner execution,
persistence, retries, lineage, and CLI diagnostics.
