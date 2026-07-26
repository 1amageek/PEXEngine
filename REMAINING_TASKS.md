# PEXEngine Remaining Tasks

Updated: 2026-07-26

The native/parser paths, Magic adapter, OpenRCX process boundary, raw
correlation, retry, lineage, and artifact verification contracts are
implemented.
No package-owned P1 implementation remains; the remaining qualification gate
requires installed extractors and foundry-authorized process views.

## Remaining tasks

| ID | Priority | Owner | Task | Exit criteria |
|---|---|---|---|---|
No package-owned P1 implementation remains.

## Completed P1 work

| ID | Completed | Evidence |
|---|---|---|
| PEX-1 | 2026-07-26 | Workspace verifier run `20260725T212810865980Z` built `PEXEngine-Package` and passed 371 tests across `PEXCoreTests`, `PEXAdaptersTests`, `PEXParsersTests`, `PEXPersistenceTests`, `PEXRuntimeTests`, and `PEXCLITests` in 27.6 seconds. |

## External prerequisites

Installed OpenROAD/OpenRCX and Magic executables plus exact foundry-authorized
LEF and extraction-rule views are external assets. Their absence remains a
typed blocked state.

| Former ID | Owner | Required evidence |
|---|---|---|
| PEX-2 | PEX qualification workflow | Same-design Magic and OpenRCX corpus reports for selected processes and corners, retaining exact inputs, executable identities, PDK/deck identities, raw outputs, canonical reports, tolerances, and independent backend classification for ToolQualification. |

## Evidence reviewed

- `GOAL_STATUS.md`
- `README.md`, including `Real Data Validation` and `Qualification boundary`
- Parser, adapter, correlation, and artifact contracts
- `Sources` incomplete-implementation marker scan
