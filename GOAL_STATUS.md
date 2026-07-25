# PEXEngine Goal Status

| Goal | Status |
|---|---|
| CircuiteFoundation dependency | Complete |
| Foundation engine protocol | Complete (`PEXExecuting`) |
| Foundation result protocols | Complete (`PEXRunResult` direct conformance) |
| Integrity-preserving artifact conversion | Complete |
| Raw implementation and correlation observations | Complete |
| OpenRCX routed-DEF production process boundary | Complete (typed blocked when OpenROAD or exact PDK views are unavailable) |
| Measured external-tool identity and output producer lineage | Complete (semantic version, executable SHA-256, invocation, environment fingerprint) |
| Immutable distinct-backend report correlation CLI | Complete |
| Implementation independence classification | Owned by ToolQualification (PEX rejects identical backend IDs but does not infer independence from names) |
| Magic retained corpus classification | Complete (regression-only; not production oracle evidence) |
| Observation artifact byte verification | Complete (tool/process/PDK/deck/corpus/report/correlation/input/output) |
| Foundation top-cell identity | Complete (`PEXRunRequest.designObjectReference`) |
| Existing extraction/parser/IR behavior | Retained |
| Retry and lineage contracts | Retained |
| Project/run orchestration | Out of scope; owned by higher layers |
| Build after identity migration | Passed; workspace verifier run `20260725T212810865980Z` built the package and passed 371 tests across all 6 declared shards |

Production trust is owned by `ToolQualification`. Backend-local corpus pass
flags and evidence packets remain raw regression material and never self-promote
to production eligibility.

The backend and correlation implementation are complete, but a production
qualification claim still requires an installed OpenROAD/OpenRCX executable,
the exact foundry-authorized LEF/rule views, and retained same-design Magic and
OpenRCX corpus reports accepted by `ToolQualification`. Absence of those
external assets is an explicit blocked state, not a PEXEngine fallback.
