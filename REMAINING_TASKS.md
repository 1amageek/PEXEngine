# PEXEngine Remaining Tasks

Updated: 2026-07-26

The native/parser paths, Magic adapter, OpenRCX process boundary, raw
correlation, retry, lineage, and artifact verification contracts are
implemented.

## Remaining tasks

| ID | Priority | Owner | Task | Exit criteria |
|---|---|---|---|---|
| PEX-2 | P1 | PEXEngine and qualification workflow | Retain same-design Magic and OpenRCX corpus reports for the selected process and corners. | Exact inputs, executable identities, PDK/deck identities, raw outputs, canonical reports, tolerances, and independent backend classification are retained and accepted by ToolQualification without self-oracle promotion. |

## Completed P1 work

| ID | Completed | Evidence |
|---|---|---|
| PEX-1 | 2026-07-26 | Workspace verifier run `20260725T212810865980Z` built `PEXEngine-Package` and passed 371 tests across `PEXCoreTests`, `PEXAdaptersTests`, `PEXParsersTests`, `PEXPersistenceTests`, `PEXRuntimeTests`, and `PEXCLITests` in 27.6 seconds. |

## External prerequisites

Installed OpenROAD/OpenRCX and Magic executables plus exact foundry-authorized
LEF and extraction-rule views are external assets. Their absence remains a
typed blocked state.

## Evidence reviewed

- `GOAL_STATUS.md`
- `README.md`, including `Real Data Validation` and `Qualification boundary`
- Parser, adapter, correlation, and artifact contracts
- `Sources` incomplete-implementation marker scan
